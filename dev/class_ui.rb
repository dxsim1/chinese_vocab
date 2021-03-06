Chinese::Vocab.words('/path/to/words.csv', 1)
# Uses :encoding => 'utf-8' internally
# Returns a string of characters

# @words_not_found   = []
# @sentences         = []
# @unique_characters = []

# words = String of not yet cleaned words
sentences = Chinese::Vocab(words, :compress => true).new do |words|
  words.sentences(:source => 'nciku', :size => :small, :with_pinyin => true)  # alias: minimum_sentences
  words.min_sentences(:source => 'nciku', :size => :small, :with_pinyin => true)  # alias: minimum_sentences
  words.to_cvs('path/to/file.csv', :col_sep => '|')
end
