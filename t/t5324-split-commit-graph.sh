#!/bin/sh

test_description='split commit graph'
. ./test-lib.sh

GIT_TEST_COMMIT_GRAPH=0
GIT_TEST_COMMIT_GRAPH_CHANGED_PATHS=0

test_expect_success 'setup repo' '
	git init &&
	git config core.commitGraph true &&
	git config gc.writeCommitGraph false &&
	infodir=".git/objects/info" &&
	graphdir="$infodir/commit-graphs" &&
	test_oid_cache <<-EOM
	shallow sha1:2132
	shallow sha256:2436

	base sha1:1408
	base sha256:1528
	EOM
'

graph_read_expect() {
	NUM_BASE=0
	if test ! -z $2
	then
		NUM_BASE=$2
	fi
	cat >expect <<- EOF
	header: 43475048 1 1 4 $NUM_BASE
	num_commits: $1
	chunks: oid_fanout oid_lookup commit_metadata generation_data
	EOF
	test-tool read-graph >output &&
	test_cmp expect output
}

test_expect_success POSIXPERM 'tweak umask for modebit tests' '
	umask 022
'

test_expect_success 'create commits and write commit-graph' '
	for i in $(test_seq 3)
	do
		test_commit $i &&
		git branch commits/$i || return 1
	done &&
	git commit-graph write --reachable &&
	test_path_is_file $infodir/commit-graph &&
	graph_read_expect 3
'

graph_git_two_modes() {
	git -c core.commitGraph=true $1 >output
	git -c core.commitGraph=false $1 >expect
	test_cmp expect output
}

graph_git_behavior() {
	MSG=$1
	BRANCH=$2
	COMPARE=$3
	test_expect_success "check normal git operations: $MSG" '
		graph_git_two_modes "log --oneline $BRANCH" &&
		graph_git_two_modes "log --topo-order $BRANCH" &&
		graph_git_two_modes "log --graph $COMPARE..$BRANCH" &&
		graph_git_two_modes "branch -vv" &&
		graph_git_two_modes "merge-base -a $BRANCH $COMPARE"
	'
}

graph_git_behavior 'graph exists' commits/3 commits/1

verify_chain_files_exist() {
	for hash in $(cat $1/commit-graph-chain)
	do
		test_path_is_file $1/graph-$hash.graph || return 1
	done
}

test_expect_success 'add more commits, and write a new base graph' '
	git reset --hard commits/1 &&
	for i in $(test_seq 4 5)
	do
		test_commit $i &&
		git branch commits/$i || return 1
	done &&
	git reset --hard commits/2 &&
	for i in $(test_seq 6 10)
	do
		test_commit $i &&
		git branch commits/$i || return 1
	done &&
	git reset --hard commits/2 &&
	git merge commits/4 &&
	git branch merge/1 &&
	git reset --hard commits/4 &&
	git merge commits/6 &&
	git branch merge/2 &&
	git commit-graph write --reachable &&
	graph_read_expect 12
'

test_expect_success 'fork and fail to base a chain on a commit-graph file' '
	test_when_finished rm -rf fork &&
	git clone . fork &&
	(
		cd fork &&
		rm .git/objects/info/commit-graph &&
		echo "$(pwd)/../.git/objects" >.git/objects/info/alternates &&
		test_commit new-commit &&
		git commit-graph write --reachable --split &&
		test_path_is_file $graphdir/commit-graph-chain &&
		test_line_count = 1 $graphdir/commit-graph-chain &&
		verify_chain_files_exist $graphdir
	)
'

test_expect_success 'add three more commits, write a tip graph' '
	git reset --hard commits/3 &&
	git merge merge/1 &&
	git merge commits/5 &&
	git merge merge/2 &&
	git branch merge/3 &&
	git commit-graph write --reachable --split &&
	test_path_is_missing $infodir/commit-graph &&
	test_path_is_file $graphdir/commit-graph-chain &&
	ls $graphdir/graph-*.graph >graph-files &&
	test_line_count = 2 graph-files &&
	verify_chain_files_exist $graphdir
'

graph_git_behavior 'split commit-graph: merge 3 vs 2' merge/3 merge/2

test_expect_success 'add one commit, write a tip graph' '
	test_commit 11 &&
	git branch commits/11 &&
	git commit-graph write --reachable --split &&
	test_path_is_missing $infodir/commit-graph &&
	test_path_is_file $graphdir/commit-graph-chain &&
	ls $graphdir/graph-*.graph >graph-files &&
	test_line_count = 3 graph-files &&
	verify_chain_files_exist $graphdir
'

graph_git_behavior 'three-layer commit-graph: commit 11 vs 6' commits/11 commits/6

test_expect_success 'add one commit, write a merged graph' '
	test_commit 12 &&
	git branch commits/12 &&
	git commit-graph write --reachable --split &&
	test_path_is_file $graphdir/commit-graph-chain &&
	test_line_count = 2 $graphdir/commit-graph-chain &&
	ls $graphdir/graph-*.graph >graph-files &&
	test_line_count = 2 graph-files &&
	verify_chain_files_exist $graphdir
'

graph_git_behavior 'merged commit-graph: commit 12 vs 6' commits/12 commits/6

test_expect_success 'create fork and chain across alternate' '
	git clone . fork &&
	(
		cd fork &&
		git config core.commitGraph true &&
		rm -rf $graphdir &&
		echo "$(pwd)/../.git/objects" >.git/objects/info/alternates &&
		test_commit 13 &&
		git branch commits/13 &&
		git commit-graph write --reachable --split &&
		test_path_is_file $graphdir/commit-graph-chain &&
		test_line_count = 3 $graphdir/commit-graph-chain &&
		ls $graphdir/graph-*.graph >graph-files &&
		test_line_count = 1 graph-files &&
		git -c core.commitGraph=true  rev-list HEAD >expect &&
		git -c core.commitGraph=false rev-list HEAD >actual &&
		test_cmp expect actual &&
		test_commit 14 &&
		git commit-graph write --reachable --split --object-dir=.git/objects/ &&
		test_line_count = 3 $graphdir/commit-graph-chain &&
		ls $graphdir/graph-*.graph >graph-files &&
		test_line_count = 1 graph-files
	)
'

graph_git_behavior 'alternate: commit 13 vs 6' commits/13 commits/6

test_expect_success 'test merge stragety constants' '
	git clone . merge-2 &&
	(
		cd merge-2 &&
		git config core.commitGraph true &&
		test_line_count = 2 $graphdir/commit-graph-chain &&
		test_commit 14 &&
		git commit-graph write --reachable --split --size-multiple=2 &&
		test_line_count = 3 $graphdir/commit-graph-chain

	) &&
	git clone . merge-10 &&
	(
		cd merge-10 &&
		git config core.commitGraph true &&
		test_line_count = 2 $graphdir/commit-graph-chain &&
		test_commit 14 &&
		git commit-graph write --reachable --split --size-multiple=10 &&
		test_line_count = 1 $graphdir/commit-graph-chain &&
		ls $graphdir/graph-*.graph >graph-files &&
		test_line_count = 1 graph-files
	) &&
	git clone . merge-10-expire &&
	(
		cd merge-10-expire &&
		git config core.commitGraph true &&
		test_line_count = 2 $graphdir/commit-graph-chain &&
		test_commit 15 &&
		touch $graphdir/to-delete.graph $graphdir/to-keep.graph &&
		test-tool chmtime =1546362000 $graphdir/to-delete.graph &&
		test-tool chmtime =1546362001 $graphdir/to-keep.graph &&
		git commit-graph write --reachable --split --size-multiple=10 \
			--expire-time="2019-01-01 12:00 -05:00" &&
		test_line_count = 1 $graphdir/commit-graph-chain &&
		test_path_is_missing $graphdir/to-delete.graph &&
		test_path_is_file $graphdir/to-keep.graph &&
		ls $graphdir/graph-*.graph >graph-files &&
		test_line_count = 3 graph-files
	) &&
	git clone --no-hardlinks . max-commits &&
	(
		cd max-commits &&
		git config core.commitGraph true &&
		test_line_count = 2 $graphdir/commit-graph-chain &&
		test_commit 16 &&
		test_commit 17 &&
		git commit-graph write --reachable --split --max-commits=1 &&
		test_line_count = 1 $graphdir/commit-graph-chain &&
		ls $graphdir/graph-*.graph >graph-files &&
		test_line_count = 1 graph-files
	)
'

test_expect_success 'remove commit-graph-chain file after flattening' '
	git clone . flatten &&
	(
		cd flatten &&
		test_line_count = 2 $graphdir/commit-graph-chain &&
		git commit-graph write --reachable &&
		test_path_is_missing $graphdir/commit-graph-chain &&
		ls $graphdir >graph-files &&
		test_line_count = 0 graph-files
	)
'

corrupt_file() {
	file=$1
	pos=$2
	data="${3:-\0}"
	chmod a+w "$file" &&
	printf "$data" | dd of="$file" bs=1 seek="$pos" conv=notrunc
}

test_expect_success 'verify hashes along chain, even in shallow' '
	git clone --no-hardlinks . verify &&
	(
		cd verify &&
		git commit-graph verify &&
		base_file=$graphdir/graph-$(head -n 1 $graphdir/commit-graph-chain).graph &&
		corrupt_file "$base_file" $(test_oid shallow) "\01" &&
		test_must_fail git commit-graph verify --shallow 2>test_err &&
		grep -v "^+" test_err >err &&
		test_i18ngrep "incorrect checksum" err
	)
'

test_expect_success 'verify --shallow does not check base contents' '
	git clone --no-hardlinks . verify-shallow &&
	(
		cd verify-shallow &&
		git commit-graph verify &&
		base_file=$graphdir/graph-$(head -n 1 $graphdir/commit-graph-chain).graph &&
		corrupt_file "$base_file" 1000 "\01" &&
		git commit-graph verify --shallow &&
		test_must_fail git commit-graph verify 2>test_err &&
		grep -v "^+" test_err >err &&
		test_i18ngrep "incorrect checksum" err
	)
'

test_expect_success 'warn on base graph chunk incorrect' '
	git clone --no-hardlinks . base-chunk &&
	(
		cd base-chunk &&
		git commit-graph verify &&
		base_file=$graphdir/graph-$(tail -n 1 $graphdir/commit-graph-chain).graph &&
		corrupt_file "$base_file" $(test_oid base) "\01" &&
		git commit-graph verify --shallow 2>test_err &&
		grep -v "^+" test_err >err &&
		test_i18ngrep "commit-graph chain does not match" err
	)
'

test_expect_success 'verify after commit-graph-chain corruption' '
	git clone --no-hardlinks . verify-chain &&
	(
		cd verify-chain &&
		corrupt_file "$graphdir/commit-graph-chain" 60 "G" &&
		git commit-graph verify 2>test_err &&
		grep -v "^+" test_err >err &&
		test_i18ngrep "invalid commit-graph chain" err &&
		corrupt_file "$graphdir/commit-graph-chain" 60 "A" &&
		git commit-graph verify 2>test_err &&
		grep -v "^+" test_err >err &&
		test_i18ngrep "unable to find all commit-graph files" err
	)
'

test_expect_success 'verify across alternates' '
	git clone --no-hardlinks . verify-alt &&
	(
		cd verify-alt &&
		rm -rf $graphdir &&
		altdir="$(pwd)/../.git/objects" &&
		echo "$altdir" >.git/objects/info/alternates &&
		git commit-graph verify --object-dir="$altdir/" &&
		test_commit extra &&
		git commit-graph write --reachable --split &&
		tip_file=$graphdir/graph-$(tail -n 1 $graphdir/commit-graph-chain).graph &&
		corrupt_file "$tip_file" 100 "\01" &&
		test_must_fail git commit-graph verify --shallow 2>test_err &&
		grep -v "^+" test_err >err &&
		test_i18ngrep "commit-graph has incorrect fanout value" err
	)
'

test_expect_success 'add octopus merge' '
	git reset --hard commits/10 &&
	git merge commits/3 commits/4 &&
	git branch merge/octopus &&
	git commit-graph write --reachable --split &&
	git commit-graph verify --progress 2>err &&
	test_line_count = 3 err &&
	test_i18ngrep ! warning err &&
	test_line_count = 3 $graphdir/commit-graph-chain
'

graph_git_behavior 'graph exists' merge/octopus commits/12

test_expect_success 'split across alternate where alternate is not split' '
	git commit-graph write --reachable &&
	test_path_is_file .git/objects/info/commit-graph &&
	cp .git/objects/info/commit-graph . &&
	git clone --no-hardlinks . alt-split &&
	(
		cd alt-split &&
		rm -f .git/objects/info/commit-graph &&
		echo "$(pwd)"/../.git/objects >.git/objects/info/alternates &&
		test_commit 18 &&
		git commit-graph write --reachable --split &&
		test_line_count = 1 $graphdir/commit-graph-chain
	) &&
	test_cmp commit-graph .git/objects/info/commit-graph
'

test_expect_success '--split=no-merge always writes an incremental' '
	test_when_finished rm -rf a b &&
	rm -rf $graphdir $infodir/commit-graph &&
	git reset --hard commits/2 &&
	git rev-list HEAD~1 >a &&
	git rev-list HEAD >b &&
	git commit-graph write --split --stdin-commits <a &&
	git commit-graph write --split=no-merge --stdin-commits <b &&
	test_line_count = 2 $graphdir/commit-graph-chain
'

test_expect_success '--split=replace replaces the chain' '
	rm -rf $graphdir $infodir/commit-graph &&
	git reset --hard commits/3 &&
	git rev-list -1 HEAD~2 >a &&
	git rev-list -1 HEAD~1 >b &&
	git rev-list -1 HEAD >c &&
	git commit-graph write --split=no-merge --stdin-commits <a &&
	git commit-graph write --split=no-merge --stdin-commits <b &&
	git commit-graph write --split=no-merge --stdin-commits <c &&
	test_line_count = 3 $graphdir/commit-graph-chain &&
	git commit-graph write --stdin-commits --split=replace <b &&
	test_path_is_missing $infodir/commit-graph &&
	test_path_is_file $graphdir/commit-graph-chain &&
	ls $graphdir/graph-*.graph >graph-files &&
	test_line_count = 1 graph-files &&
	verify_chain_files_exist $graphdir &&
	graph_read_expect 2
'

test_expect_success ULIMIT_FILE_DESCRIPTORS 'handles file descriptor exhaustion' '
	git init ulimit &&
	(
		cd ulimit &&
		for i in $(test_seq 64)
		do
			test_commit $i &&
			run_with_limited_open_files test_might_fail git commit-graph write \
				--split=no-merge --reachable || return 1
		done
	)
'

while read mode modebits
do
	test_expect_success POSIXPERM "split commit-graph respects core.sharedrepository $mode" '
		rm -rf $graphdir $infodir/commit-graph &&
		git reset --hard commits/1 &&
		test_config core.sharedrepository "$mode" &&
		git commit-graph write --split --reachable &&
		ls $graphdir/graph-*.graph >graph-files &&
		test_line_count = 1 graph-files &&
		echo "$modebits" >expect &&
		test_modebits $graphdir/graph-*.graph >actual &&
		test_cmp expect actual &&
		test_modebits $graphdir/commit-graph-chain >actual &&
		test_cmp expect actual
	'
done <<\EOF
0666 -r--r--r--
0600 -r--------
EOF

test_done
