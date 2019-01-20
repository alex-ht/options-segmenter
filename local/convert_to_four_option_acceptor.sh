#!/bin/bash
. ./path.sh

if [ $# != 2 ]; then
   echo "Usage: $0 [options] <old-lang-dir> <new-lang-dir>"
   echo "e.g.: $0 data/lang_test data/lang_test_4op"
   exit 1;
fi

# lang是原本有G.fst的目錄
lang=$1
# dir是輸出修改後的
dir=$2

[ -d $dir ] && mv $dir ${dir}.bak
cp -r $lang $dir
mkdir -p $dir/tmp

cat <<EOF > $dir/tmp/O.txt
0	1	壹	壹
1	2	#W	#W
2	3	貳	貳
3	4	#W	#W
4	5	參	參
5	6	#W	#W
6	7	肆	肆
7	8	#W	#W
8
EOF

cut -d\  -f 1 $lang/phones/align_lexicon.txt | grep -v '<eps>' |\
  awk '{printf("0 0 %s %s\n", $1, $1)}END{print "0"}' | \
  fstcompile --isymbols=$lang/words.txt --osymbols=$lang/words.txt > $dir/tmp/w.fst

(cut -d\  -f 1 $lang/words.txt ; echo "#W"; echo "#ROOT") | awk '{print $1 " " NR-1}' > $dir/words.txt
fstcompile --isymbols=$dir/words.txt --osymbols=$dir/words.txt $dir/tmp/O.txt $dir/tmp/O.tmp
fstreplace --epsilon_on_replace $dir/tmp/O.tmp $(echo "#ROOT" | utils/sym2int.pl $dir/words.txt) $dir/tmp/w.fst $(echo "#W" | utils/sym2int.pl $dir/words.txt) |
  fstdeterminizestar | fstminimizeencoded | fstarcsort --sort_type=ilabel > $dir/tmp/O.fst
fstisstochastic $dir/tmp/O.fst

fstarcsort --sort_type=olabel $lang/G.fst | fstcompose - $dir/tmp/O.fst | fstarcsort > $dir/G.fst
set e
fstisstochastic $dir/G.fst
exit 0;
