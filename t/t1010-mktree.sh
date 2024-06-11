#!/bin/sh

test_description='git mktree'

TEST_PASSES_SANITIZE_LEAK=true
. ./test-lib.sh

test_expect_success setup '
	for d in a a- a0
	do
		mkdir "$d" && echo "$d/one" >"$d/one" &&
		git add "$d" || return 1
	done &&
	echo zero >one &&
	git update-index --add --info-only one &&
	git write-tree --missing-ok >tree.missing &&
	git ls-tree $(cat tree.missing) >top.missing &&
	git ls-tree -r $(cat tree.missing) >all.missing &&
	echo one >one &&
	git add one &&
	git write-tree >tree &&
	git ls-tree $(cat tree) >top &&
	git ls-tree -r $(cat tree) >all &&
	test_tick &&
	git commit -q -m one &&
	H=$(git rev-parse HEAD) &&
	git update-index --add --cacheinfo 160000 $H sub &&
	test_tick &&
	git commit -q -m two &&
	git rev-parse HEAD^{tree} >tree.withsub &&
	git ls-tree HEAD >top.withsub &&
	git ls-tree -r HEAD >all.withsub
'

test_expect_success 'ls-tree piped to mktree (1)' '
	git mktree <top >actual &&
	test_cmp tree actual
'

test_expect_success 'ls-tree piped to mktree (2)' '
	git mktree <top.withsub >actual &&
	test_cmp tree.withsub actual
'

test_expect_success 'ls-tree output in wrong order given to mktree (1)' '
	perl -e "print reverse <>" <top |
	git mktree >actual &&
	test_cmp tree actual
'

test_expect_success 'ls-tree output in wrong order given to mktree (2)' '
	perl -e "print reverse <>" <top.withsub |
	git mktree >actual &&
	test_cmp tree.withsub actual
'

test_expect_success '--batch creates multiple trees' '
	cat top >multi-tree &&
	echo "" >>multi-tree &&
	cat top.withsub >>multi-tree &&

	cat tree >expect &&
	cat tree.withsub >>expect &&
	git mktree --batch <multi-tree >actual &&
	test_cmp expect actual
'

test_expect_success 'allow missing object with --missing' '
	git mktree --missing <top.missing >actual &&
	test_cmp tree.missing actual
'

test_expect_success 'mktree with invalid submodule OIDs' '
	# non-existent OID - ok
	printf "160000 commit $(test_oid numeric)\tA\n" >in &&
	git mktree <in >tree.actual &&
	git ls-tree $(cat tree.actual) >actual &&
	test_cmp in actual &&

	# existing OID, wrong type - error
	tree_oid="$(cat tree)" &&
	printf "160000 commit $tree_oid\tA" |
	test_must_fail git mktree 2>err &&
	grep "object $tree_oid is a tree but specified type was (commit)" err
'

test_expect_success 'mktree refuses to read ls-tree -r output (1)' '
	test_must_fail git mktree <all
'

test_expect_success 'mktree refuses to read ls-tree -r output (2)' '
	test_must_fail git mktree <all.withsub
'

test_expect_success 'mktree fails on malformed input' '
	# empty line without --batch
	echo "" |
	test_must_fail git mktree 2>err &&
	grep "blank line only valid in batch mode" err &&

	# bad whitespace
	printf "100644 blob $EMPTY_BLOB A" |
	test_must_fail git mktree 2>err &&
	grep "malformed input line" err &&

	# invalid type
	printf "100644 bad $EMPTY_BLOB\tA" |
	test_must_fail git mktree 2>err &&
	grep "invalid object type" err &&

	# invalid OID length
	printf "100755 blob abc123\tA" |
	test_must_fail git mktree 2>err &&
	grep "malformed input line" err &&

	# bad quoting
	printf "100644 blob $EMPTY_BLOB\t\"A" |
	test_must_fail git mktree 2>err &&
	grep "bad quoting of path name" err
'

test_expect_success 'mktree fails on mode mismatch' '
	tree_oid="$(cat tree)" &&

	# mode-type mismatch
	printf "100644 tree $tree_oid\tA" |
	test_must_fail git mktree 2>err &&
	grep "object type (tree) doesn${SQ}t match mode type (blob)" err &&

	# mode-object mismatch (no --missing)
	printf "100644 $tree_oid\tA" |
	test_must_fail git mktree 2>err &&
	grep "object $tree_oid is a tree but specified type was (blob)" err
'

test_expect_success '--literally can create invalid trees' '
	tree_oid="$(cat tree)" &&
	blob_oid="$(git rev-parse ${tree_oid}:one)" &&

	# duplicate entries
	{
		printf "040000 tree $tree_oid\tmy-tree\n" &&
		printf "100644 blob $blob_oid\ttest-file\n" &&
		printf "100755 blob $blob_oid\ttest-file\n"
	} | git mktree --literally >tree.bad &&
	git cat-file tree $(cat tree.bad) >top.bad &&
	test_must_fail git hash-object --stdin -t tree <top.bad 2>err &&
	grep "contains duplicate file entries" err &&

	# disallowed path
	{
		printf "100644 blob $blob_oid\t.git\n"
	} | git mktree --literally >tree.bad &&
	git cat-file tree $(cat tree.bad) >top.bad &&
	test_must_fail git hash-object --stdin -t tree <top.bad 2>err &&
	grep "contains ${SQ}.git${SQ}" err &&

	# nested entry
	{
		printf "100644 blob $blob_oid\tdeeper/my-file\n"
	} | git mktree --literally >tree.bad &&
	git cat-file tree $(cat tree.bad) >top.bad &&
	test_must_fail git hash-object --stdin -t tree <top.bad 2>err &&
	grep "contains full pathnames" err &&

	# bad entry ordering
	{
		printf "100644 blob $blob_oid\tB\n" &&
		printf "040000 tree $tree_oid\tA\n"
	} | git mktree --literally >tree.bad &&
	git cat-file tree $(cat tree.bad) >top.bad &&
	test_must_fail git hash-object --stdin -t tree <top.bad 2>err &&
	grep "not properly sorted" err
'

test_done
