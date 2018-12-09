#!/bin/bash
# Copyright 2015-2016  Sarah Flora Juan
# Copyright 2016  Johns Hopkins University (Author: Yenda Trmal)
# Apache 2.0

set -e -o pipefail

corpus=NER-Trs-Vol1/Train
. ./utils/parse_options.sh

if [ -z "$corpus" ] ; then
    echo >&2 "The script $0 expects one parameter -- the location of the LibriSpeech corpus"
    exit 1
fi
if [ ! -d "$corpus" ] ; then
    echo >&2 "The directory $corpus does not exist"
fi

# have to remvoe previous files to avoid filtering speakers according to cmvn.scp and feats.scp
rm -rf        data/all
mkdir -p data data/all

#
# make utt2spk, wav.scp and text
#

rm -f data/all/utt2spk
rm -f data/all/wav.scp
rm -f data/all/text
touch data/all/utt2spk
touch data/all/wav.scp
touch data/all/text
find $corpus -name *.wav -exec sh -c 'x={}; y=${x%.wav}; printf "%s %s\n"     $y $y' \; | dos2unix > data/all/utt2spk
find $corpus -name *.wav -exec sh -c 'x={}; y=${x%.wav}; printf "%s %s\n"     $y $x' \; | dos2unix > data/all/wav.scp
find $corpus -name *.txt -exec sh -c 'x={}; y=${x%.txt}; printf "%s " $y; cat $x'    \; | dos2unix | sed 's/\/Text\//\/Wav\//' > data/all/text

utils/fix_data_dir.sh data/all

echo "Data preparation completed."

