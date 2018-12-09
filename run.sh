#!/bin/bash
set -exu
. ./cmd.sh

stage=-10
num_jobs=8
suffix=_any

. ./path.sh
. ./utils/parse_options.sh
unset LC_ALL;

if [ $stage -le -2 ]; then
  # Lexicon Preparation,
  echo "$0: Lexicon Preparation"
  local/prepare_dict.sh || exit 1;

  # Data Preparation
  echo "$0: Data Preparation"
  local/prepare_data.sh || exit 1;
fi

if [ $stage -le -1 ]; then
  utils/subset_data_dir.sh data/all 5000 data/train${suffix}5k
  LANG="zh_TW.UTF-8" local/replace_label.py < data/all/text > data/train${suffix}5k/text
  # add prefix
  for x in text  utt2dur  utt2num_frames  wav.scp; do
    [ -f data/train${suffix}5k/$x ] && sed -i 's:^:ANY_:g' data/train${suffix}5k/$x;
  done
  awk '{print $1 " " $1}' data/train${suffix}5k/wav.scp > data/train${suffix}5k/utt2spk
  rm data/train${suffix}5k/spk2utt
  utils/fix_data_dir.sh data/train${suffix}5k
fi

if [ $stage -le 0 ]; then
  [ ! -f data/local/dict/lexicon.txt ] && echo "please run ./local/prepare_dict.sh" && exit 1;
  [ -f data/local/dict/lexiconp.txt ] && rm data/local/dict/lexiconp.txt
  echo "<ANY> ANY1 ANY2" >> data/local/dict/lexicon.txt
  echo "<SPN> SPN" >> data/local/dict/lexicon.txt
  echo "ANY1" >> data/local/dict/nonsilence_phones.txt
  echo "ANY2" >> data/local/dict/nonsilence_phones.txt
  echo "SPN" >> data/local/dict/nonsilence_phones.txt
  for x in lexicon.txt nonsilence_phones.txt; do
    LC_ALL="C" sort data/local/dict/$x | uniq > data/local/dict/${x}.tmp
    mv data/local/dict/${x}.tmp data/local/dict/$x
  done
  [ -f data/lang${suffix}/G.fst ] && rm data/lang${suffix}/G.fst
  utils/prepare_lang.sh \
    --position-dependent-phones true \
    --num-sil-states 1 \
    data/local/dict "<SPN>" data/local/lang data/lang${suffix}
  LANG="zh_TW.UTF-8" local/generate_grammar.py | \
    fstcompile --isymbols=data/lang${suffix}/words.txt \
               --osymbols=data/lang${suffix}/words.txt | fstarcsort > data/lang${suffix}/G.fst
fi

if [ $stage -le 1 ]; then
  echo "$0: making mfccs"
  for x in all train${suffix}5k finetune test; do
    if [ ! -f data/$x/feats.scp ]; then
      steps/make_mfcc_pitch.sh --cmd "$train_cmd" --nj $num_jobs data/$x
      steps/compute_cmvn_stats.sh data/$x
      utils/fix_data_dir.sh data/$x
    fi
  done
  utils/combine_data.sh data/train${suffix}_comb data/all data/train${suffix}5k
fi

# mono
if [ $stage -le 2 ]; then
  # train mono
  steps/train_mono.sh --boost-silence 1.25 --cmd "$train_cmd" --nj $num_jobs \
    data/train${suffix}_comb data/lang${suffix} exp${suffix}/mono

  # Get alignments from monophone system.
  steps/align_si.sh --boost-silence 1.25 --cmd "$train_cmd" --nj $num_jobs \
    data/train${suffix}_comb data/lang${suffix} exp${suffix}/mono exp${suffix}/mono_ali
fi

# triphone
if [ $stage -le 3 ]; then
  echo "$0: train tri1 model"
  # train tri1 [first triphone pass]
  steps/train_deltas.sh --boost-silence 1.25 --cmd "$train_cmd" \
    2500 20000 data/train${suffix}_comb data/lang${suffix} exp${suffix}/mono_ali exp${suffix}/tri1

  # align tri1
  steps/align_si.sh --cmd "$train_cmd" --nj $num_jobs \
    data/train${suffix}_comb data/lang${suffix} exp${suffix}/tri1 exp${suffix}/tri1_ali

  echo "$0: train tri2 model"
  # train tri2 [delta+delta-deltas]
  steps/train_deltas.sh --cmd "$train_cmd" \
    2500 20000 data/train${suffix}_comb data/lang${suffix} exp${suffix}/tri1_ali exp${suffix}/tri2

  # align tri2
  steps/align_si.sh --cmd "$train_cmd" --nj $num_jobs \
    data/train${suffix}_comb data/lang${suffix} exp${suffix}/tri2 exp${suffix}/tri2_ali
fi

if [ $stage -le 4 ]; then
  echo "$0: train tri3 model"
  # tri3
  steps/train_sat_basis.sh --cmd "$train_cmd" \
    2500 20000 data/train${suffix}_comb data/lang${suffix} exp${suffix}/tri2_ali exp${suffix}/tri3

  # align tri3
  steps/align_basis_fmllr.sh  --cmd "$train_cmd" --nj $num_jobs \
    data/train${suffix}_comb data/lang${suffix} exp${suffix}/tri3 exp${suffix}/tri3_ali
  echo "$0: train tri4 model"
  # Building a larger SAT system.
  steps/train_sat_basis.sh --cmd "$train_cmd" \
    3500 100000 data/train${suffix}_comb data/lang${suffix} exp${suffix}/tri3_ali exp${suffix}/tri4

fi

if [ $stage -le 5 ]; then
  echo "$0: finetuneing"
  # align tri4
  steps/align_basis_fmllr.sh --cmd "$train_cmd" --nj 1 \
    data/finetune data/lang${suffix} exp${suffix}/tri4 exp${suffix}/tri4_finetune_ali

  # decode tri5
  $mkgraph_cmd exp${suffix}/tri4/log/mkgraph.log \
    utils/mkgraph.sh data/lang${suffix} exp${suffix}/tri4 exp${suffix}/tri4/graph

  steps/decode_basis_fmllr.sh --cmd "$decode_cmd" --nj 1 \
    --scoring-opts "--min-lmwt 1 --max-lmwt 1 --word-ins-penalty 0.0" \
    exp${suffix}/tri4/graph data/finetune exp${suffix}/tri4/decode_finetune

  steps/train_mmi.sh --cmd "$train_cmd" \
    data/finetune data/lang${suffix} exp${suffix}/tri4_finetune_ali exp${suffix}/tri4/decode_finetune exp${suffix}/tri4_mmi
fi

if [ $stage -le 6 ]; then
  steps/online/prepare_online_decoding.sh --add-pitch true --cmd "$train_cmd" \
    data/all data/lang${suffix} exp${suffix}/tri4 exp${suffix}/tri4_mmi/final.mdl exp${suffix}/tri4_online

  steps/online/decode.sh --cmd "$decode_cmd" --nj 1 \
     --scoring-opts "--min-lmwt 1 --max-lmwt 1 --word-ins-penalty 0.0" \
     exp${suffix}/tri4/graph data/test exp${suffix}/tri4_online/decode_test

  utils/show_lattice.sh --mode save T0001 exp${suffix}/tri4_online/decode_test/lat.1.gz data/lang${suffix}/words.txt
fi
