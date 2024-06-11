/*
 * GIT - the stupid content tracker
 *
 * Copyright (c) Junio C Hamano, 2006, 2009
 */
#include "builtin.h"
#include "cache-tree.h"
#include "gettext.h"
#include "hex.h"
#include "index-info.h"
#include "quote.h"
#include "read-cache-ll.h"
#include "strbuf.h"
#include "tree.h"
#include "parse-options.h"
#include "object-store-ll.h"

struct tree_entry {
	/* Internal */
	size_t order;

	unsigned mode;
	struct object_id oid;
	int len;
	char name[FLEX_ARRAY];
};

static inline size_t df_path_len(size_t pathlen, unsigned int mode)
{
	return S_ISDIR(mode) ? pathlen - 1 : pathlen;
}

struct tree_entry_array {
	size_t nr, alloc;
	struct tree_entry **entries;
};

static void tree_entry_array_push(struct tree_entry_array *arr, struct tree_entry *ent)
{
	ALLOC_GROW(arr->entries, arr->nr + 1, arr->alloc);
	arr->entries[arr->nr++] = ent;
}

static void clear_tree_entry_array(struct tree_entry_array *arr)
{
	for (size_t i = 0; i < arr->nr; i++)
		FREE_AND_NULL(arr->entries[i]);
	arr->nr = 0;
}

static void release_tree_entry_array(struct tree_entry_array *arr)
{
	FREE_AND_NULL(arr->entries);
	arr->nr = arr->alloc = 0;
}

static void append_to_tree(unsigned mode, struct object_id *oid, const char *path,
			   struct tree_entry_array *arr, int literally)
{
	struct tree_entry *ent;
	size_t len = strlen(path);

	if (literally) {
		FLEX_ALLOC_MEM(ent, name, path, len);
	} else {
		size_t len_to_copy = len;

		/* Normalize and validate entry path */
		if (S_ISDIR(mode)) {
			while(len_to_copy > 0 && is_dir_sep(path[len_to_copy - 1]))
				len_to_copy--;
			len = len_to_copy + 1; /* add space for trailing slash */
		}
		ent = xcalloc(1, st_add3(sizeof(struct tree_entry), len, 1));
		memcpy(ent->name, path, len_to_copy);

		if (!verify_path(ent->name, mode))
			die(_("invalid path '%s'"), path);
		if (strchr(ent->name, '/'))
			die("path %s contains slash", path);

		/* Add trailing slash to dir */
		if (S_ISDIR(mode))
			ent->name[len - 1] = '/';
	}

	ent->mode = mode;
	ent->len = len;
	oidcpy(&ent->oid, oid);

	/* Append the update */
	ent->order = arr->nr;
	tree_entry_array_push(arr, ent);
}

static int ent_compare(const void *a_, const void *b_, void *ctx)
{
	int cmp;
	struct tree_entry *a = *(struct tree_entry **)a_;
	struct tree_entry *b = *(struct tree_entry **)b_;
	int ignore_mode = *((int *)ctx);

	size_t a_len = a->len, b_len = b->len;

	if (ignore_mode) {
		a_len = df_path_len(a_len, a->mode);
		b_len = df_path_len(b_len, b->mode);
	}

	cmp = name_compare(a->name, a_len, b->name, b_len);
	return cmp ? cmp : b->order - a->order;
}

static void sort_and_dedup_tree_entry_array(struct tree_entry_array *arr)
{
	size_t count = arr->nr;
	struct tree_entry *prev = NULL;

	int ignore_mode = 1;
	QSORT_S(arr->entries, arr->nr, ent_compare, &ignore_mode);

	arr->nr = 0;
	for (size_t i = 0; i < count; i++) {
		struct tree_entry *curr = arr->entries[i];
		if (prev &&
		    !name_compare(prev->name, df_path_len(prev->len, prev->mode),
				  curr->name, df_path_len(curr->len, curr->mode))) {
			FREE_AND_NULL(curr);
		} else {
			arr->entries[arr->nr++] = curr;
			prev = curr;
		}
	}

	/* Sort again to order the entries for tree insertion */
	ignore_mode = 0;
	QSORT_S(arr->entries, arr->nr, ent_compare, &ignore_mode);
}

struct tree_entry_iterator {
	struct tree_entry *current;

	/* private */
	struct {
		struct tree_entry_array *arr;
		size_t idx;
	} priv;
};

static void init_tree_entry_iterator(struct tree_entry_iterator *iter,
				     struct tree_entry_array *arr)
{
	iter->priv.arr = arr;
	iter->priv.idx = 0;
	iter->current = 0 < arr->nr ? arr->entries[0] : NULL;
}

/*
 * Advance the tree entry iterator to the next entry in the array. If no entries
 * remain, 'current' is set to NULL. Returns the previous 'current' value of the
 * iterator.
 */
static struct tree_entry *advance_tree_entry_iterator(struct tree_entry_iterator *iter)
{
	struct tree_entry *prev = iter->current;
	iter->current = (iter->priv.idx + 1) < iter->priv.arr->nr
			? iter->priv.arr->entries[++iter->priv.idx]
			: NULL;
	return prev;
}

static int add_tree_entry_to_index(struct index_state *istate,
				   struct tree_entry *ent)
{
	struct cache_entry *ce;
	struct strbuf ce_name = STRBUF_INIT;
	strbuf_add(&ce_name, ent->name, ent->len);

	ce = make_cache_entry(istate, ent->mode, &ent->oid, ent->name, 0, 0);
	if (!ce)
		return error(_("make_cache_entry failed for path '%s'"), ent->name);

	add_index_entry(istate, ce, ADD_CACHE_JUST_APPEND);
	strbuf_release(&ce_name);
	return 0;
}

static void write_tree(struct tree_entry_array *arr, struct object_id *oid)
{
	struct tree_entry_iterator iter = { NULL };
	struct tree_entry *ent;
	struct index_state istate = INDEX_STATE_INIT(the_repository);
	istate.sparse_index = 1;

	sort_and_dedup_tree_entry_array(arr);

	init_tree_entry_iterator(&iter, arr);

	/* Construct an in-memory index from the provided entries & base tree */
	while ((ent = advance_tree_entry_iterator(&iter))) {
		if (add_tree_entry_to_index(&istate, ent))
			die(_("failed to add tree entry '%s'"), ent->name);
	}

	/* Write out new tree */
	if (cache_tree_update(&istate, WRITE_TREE_SILENT | WRITE_TREE_MISSING_OK))
		die(_("failed to write tree"));
	oidcpy(oid, &istate.cache_tree->oid);

	release_index(&istate);
}

static void write_tree_literally(struct tree_entry_array *arr,
				 struct object_id *oid)
{
	struct strbuf buf;
	size_t size = 0;

	for (size_t i = 0; i < arr->nr; i++)
		size += 32 + arr->entries[i]->len;

	strbuf_init(&buf, size);
	for (size_t i = 0; i < arr->nr; i++) {
		struct tree_entry *ent = arr->entries[i];
		strbuf_addf(&buf, "%o %s%c", ent->mode, ent->name, '\0');
		strbuf_add(&buf, ent->oid.hash, the_hash_algo->rawsz);
	}

	write_object_file(buf.buf, buf.len, OBJ_TREE, oid);
	strbuf_release(&buf);
}

static const char *mktree_usage[] = {
	"git mktree [-z] [--missing] [--literally] [--batch]",
	NULL
};

struct mktree_line_data {
	struct tree_entry_array *arr;
	int allow_missing;
	int literally;
};

static int mktree_line(unsigned int mode, struct object_id *oid,
		       enum object_type obj_type, int stage UNUSED,
		       const char *path, void *cbdata)
{
	struct mktree_line_data *data = cbdata;
	enum object_type mode_type = object_type(mode);
	struct object_info oi = OBJECT_INFO_INIT;
	enum object_type parsed_obj_type;

	if (obj_type && mode_type != obj_type)
		die("object type (%s) doesn't match mode type (%s)",
		    type_name(obj_type), type_name(mode_type));

	oi.typep = &parsed_obj_type;

	if (oid_object_info_extended(the_repository, oid, &oi,
				     OBJECT_INFO_LOOKUP_REPLACE |
				     OBJECT_INFO_QUICK |
				     OBJECT_INFO_SKIP_FETCH_OBJECT) < 0)
		parsed_obj_type = -1;

	if (parsed_obj_type < 0) {
		if (data->allow_missing || S_ISGITLINK(mode)) {
			; /* no problem - missing objects & submodules are presumed to be of the right type */
		} else {
			die("entry '%s' object %s is unavailable", path, oid_to_hex(oid));
		}
	} else if (parsed_obj_type != mode_type) {
		/*
		 * The object exists but is of the wrong type.
		 * This is a problem regardless of allow_missing
		 * because the new tree entry will never be correct.
		 */
		die("entry '%s' object %s is a %s but specified type was (%s)",
		    path, oid_to_hex(oid), type_name(parsed_obj_type), type_name(mode_type));
	}

	append_to_tree(mode, oid, path, data->arr, data->literally);
	return 0;
}

int cmd_mktree(int ac, const char **av, const char *prefix)
{
	struct object_id oid;
	int nul_term_line = 0;
	int is_batch_mode = 0;
	struct tree_entry_array arr = { 0 };
	struct mktree_line_data mktree_line_data = { .arr = &arr };
	int ret;

	const struct option option[] = {
		OPT_BOOL('z', NULL, &nul_term_line, N_("input is NUL terminated")),
		OPT_BOOL(0, "missing", &mktree_line_data.allow_missing, N_("allow missing objects")),
		OPT_BOOL(0, "literally", &mktree_line_data.literally,
			 N_("do not sort, deduplicate, or validate paths of tree entries")),
		OPT_BOOL(0, "batch", &is_batch_mode, N_("allow creation of more than one tree")),
		OPT_END()
	};

	ac = parse_options(ac, av, prefix, option, mktree_usage, 0);

	do {
		ret = read_index_info(nul_term_line, mktree_line, &mktree_line_data);
		if (ret < 0)
			break;

		/* empty lines denote tree boundaries in batch mode */
		if (ret > 0 && !is_batch_mode)
			die("input format error: (blank line only valid in batch mode)");

		if (is_batch_mode && !ret && arr.nr < 1) {
			/*
			 * Execution gets here if the last tree entry is terminated with a
			 * new-line.  The final new-line has been made optional to be
			 * consistent with the original non-batch behaviour of mktree.
			 */
			; /* skip creating an empty tree */
		} else {
			if (mktree_line_data.literally)
				write_tree_literally(&arr, &oid);
			else
				write_tree(&arr, &oid);
			puts(oid_to_hex(&oid));
			fflush(stdout);
		}
		clear_tree_entry_array(&arr); /* reset tree entry buffer for re-use in batch mode */
	} while (ret > 0);

	release_tree_entry_array(&arr);
	return !!ret;
}
