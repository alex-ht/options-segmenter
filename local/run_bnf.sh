#!/bin/bash
set -eu
. ./cmd.sh

stage=0
bnf_layer=prefinal-chain.batchnorm2
lang=data/lang_any

. ./path.sh
. parse_options.sh

if [ $stage -le 0 ]; then
  for x in all; do
    utils/copy_data_dir.sh data/$x data/${x}_hires
    steps/make_mfcc_pitch.sh --cmd "$train_cmd" --nj 8 \
      --write-utt2num-frames true \
      --mfcc-config conf/mfcc_hires.conf \
      data/${x}_hires
    utils/fix_data_dir.sh data/${x}_hires
    steps/compute_cmvn_stats.sh data/${x}_hires
    utils/data/limit_feature_dim.sh 0:39 data/${x}_hires data/${x}_hires_nopitch
    steps/compute_cmvn_stats.sh data/${x}_hires_nopitch
  done
  for x in finetune test; do
    utils/copy_data_dir.sh data/$x data/${x}_hires
    steps/make_mfcc_pitch.sh --cmd "$train_cmd" --nj 1 \
      --write-utt2num-frames true \
      --mfcc-config conf/mfcc_hires.conf \
      data/${x}_hires
    utils/fix_data_dir.sh data/${x}_hires
    steps/compute_cmvn_stats.sh data/${x}_hires
    utils/data/limit_feature_dim.sh 0:39 data/${x}_hires data/${x}_hires_nopitch
    steps/compute_cmvn_stats.sh data/${x}_hires_nopitch
  done
fi

if [ $stage -le 1 ]; then
  steps/online/nnet2/extract_ivectors.sh \
    --nj 4 --cmd "$train_cmd" \
    data/all_hires_nopitch data/lang_any exp/nnet3/extractor exp/nnet3/ivectors_all

  for x in finetune test; do
    steps/online/nnet2/extract_ivectors.sh \
      --nj 1 --cmd "$train_cmd" \
      data/${x}_hires_nopitch data/lang_any exp/nnet3/extractor exp/nnet3/ivectors_${x}
  done
fi

if [ $stage -le 2 ]; then
  steps/nnet3/make_bottleneck_features.sh \
    --nj 4 --cmd "$train_cmd" --use-gpu true \
    --ivector-dir exp/nnet3/ivectors_all \
    $bnf_layer data/all_hires data/all_bnf exp/chain/tdnn_1b_sp
  for x in finetune test; do
    steps/nnet3/make_bottleneck_features.sh \
      --nj 1 --cmd "$train_cmd" --use-gpu true \
      --ivector-dir exp/nnet3/ivectors_${x} \
      $bnf_layer data/${x}_hires data/${x}_bnf exp/chain/tdnn_1b_sp
  done
fi

srcdir=exp_any/tri4
alidir=exp_any/tri4_ali
dir=exp_any/tri5_tandem
if [ $stage -le 3 ]; then
  steps/align_basis_fmllr.sh --nj 8 --cmd "$train_cmd" \
    data/all $lang $srcdir $alidir
  [ -f $alidir/trans.1 ] && rm $alidir/trans.*
  local/tandem/train_deltas.sh --cmd "$train_cmd" \
    5000 100000 data/all data/all_bnf $lang $alidir $dir
fi
srcdir=exp_any/tri5_tandem
alidir=exp_any/tri5_tandem_ali
dir=exp_any/tri6_tandem
if [ $stage -le 4 ]; then
  local/tandem/align_fmllr.sh --nj 8 --cmd "$train_cmd" \
    data/all data/all_bnf $lang $srcdir $alidir
  local/tandem/train_sat.sh --cmd "$train_cmd" \
    5000 100000 data/all data/all_bnf $lang $alidir $dir
fi

if [ $stage -le 5 ]; then
  $mkgraph_cmd $dir/log/mkgraph.log \
    utils/mkgraph.sh $lang $dir $dir/graph
  local/tandem/decode_fmllr.sh --cmd "$decode_cmd" --nj 1 \
    --scoring-opts "--min-lmwt 1 --max-lmwt 1 --word-ins-penalty 0.0" \
    $dir/graph data/finetune data/finetune_bnf $dir/decode_finetune
  local/tandem/align_fmllr.sh --nj 1 \
    data/finetune data/finetune_bnf $lang $dir ${dir}_finetune_ali
  local/tandem/train_mmi.sh --cmd "$train_cmd" \
    data/finetune data/finetune_bnf $lang ${dir}_finetune_ali ${dir}/decode_finetune ${dir}_mmi
fi

graph=$dir/graph
dir=${dir}_mmi

if [ $stage -le 6 ]; then
  local/tandem/decode_fmllr.sh --cmd "$decode_cmd" --nj 1 \
    --scoring-opts "--min-lmwt 1 --max-lmwt 1 --word-ins-penalty 0.0" \
    $graph data/test data/test_bnf $dir/decode_test
  [ -f T0001.pdf ] && mv T0001.pdf T0001.bak.pdf
  utils/show_lattice.sh --mode save T0001 $dir/decode_test/lat.1.gz $lang/words.txt
  mv T0001.pdf T0001.tandem.pdf
fi
