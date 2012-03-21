# encoding: utf-8

require 'spec_helper'

describe Chinese::Vocab do

  # NOTE:  "浮鞋" is only found on jukuu.
  words = ["我", "打", "他", "他们", "谁", "越 。。。 来越", "除了。。。 以外。。。", "浮鞋"]

  sentences = ['我打他。',
               '他打我好疼。',
               '他打谁？',
               '他们想知道你是谁。',
               '他们钱越来越多。',
               '除了饺子以外，我也很喜欢吃馒头',
               '除了饺子之外，我也很喜欢吃馒头']

  context "Class methods" do

    # data/old_hsk_short.csv:
    # "4","3571","座右銘","座右铭","zuòyòumíng","motto","n"
    # ,,,,,,                                                      => no data
    #   "4","3571","座右銘","座右铭","zuòyòumíng","motto","n"
    #                                                             => blank line
    # "4","3571","座右銘","","zuòyòumíng","motto","n"             => word column is an empty string
    # "4","3571","座右銘","    ","zuòyòumíng","motto","n"         => word column only contains whitespace
    # "4","3571","座右銘",,"zuòyòumíng","motto","n"               => word column contains no data
    # ,,,,,,

    let(:vocab) {described_class}

    context :words do

      specify {vocab.parse_words('data/old_hsk_short.csv', 4).should == ["座右铭", "座右铭"] }
    end

    context :within_range? do

      row = [:a, :b, :c, :d, :e] # 5 columns

      specify {vocab.within_range?(1, row).should be_true }
      specify {vocab.within_range?(3, row).should be_true }
      specify {vocab.within_range?(5, row).should be_true }
      specify {vocab.within_range?(6, row).should be_false }
    end
  end

  context "Instance methods" do
    let(:vocab) {described_class.new(words)}

    context :remove_parens do

      # Using ASCII parens
      specify {vocab.remove_parens("除了。。以外(之外)").should == "除了。。以外" }
      # Using Chinese parens
      specify {vocab.remove_parens("除了。。。以外（之外）").should == "除了。。。以外" }
    end

    context :edit_vocab do

      passed_to_initialize = ["除了。。以外(之外)", "除了。。。以外（之外）", "U盘", "U盘"]

      # Edit and remove duplicates
      specify {vocab.edit_vocab(passed_to_initialize).should == ["除了 以外", "U盘"] }
    end

    context :min_sentences do

      word_list = ["除了。。。 以外。。。", "浮鞋"]
      let(:new_vocab) { described_class.new(word_list) }
      specify { new_vocab.min_sentences(:with_pinyin => true).should == nil }
      # [["除了 以外", "除了这张大钞以外，我没有其他零票了。",
      #   "chú le zhè zhāng dà chāo yĭ wài ，wŏ méi yŏu qí tā líng piào le 。",
      #   "I have no change except for this high denomination banknote."]]

    end

    context :alternate_source do

      specify {vocab.alternate_source([:a, :b], :b).should == :a }
      specify {vocab.alternate_source([:a, :b], :a).should == :b }
    end

    context :is_unicode? do

      ascii   = ["hello, ....", "This is perfect!"]
      chinese = ["U盘", "X光", "周易衡"]

      specify { ascii.all? {|word| vocab.is_unicode?(word) }.should be_false }
      specify { chinese.all? {|word| vocab.is_unicode?(word) }.should be_true }

    end

    context :distinct_words do

      specify { vocab.distinct_words(words[5]).should == ["越", "来越"] }
      specify { vocab.distinct_words(words[6]).should == ["除了", "以外"] }

    end

    context :include_every_char? do

      # word: "越 来越", sentence: '他们钱越来越多。'
      specify { vocab.include_every_char?(words[5], sentences[4]).should be_true }

    end
  end
end



