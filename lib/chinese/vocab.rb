# encoding: utf-8
require 'thread'
require 'open-uri'
require 'nokogiri'
require 'cgi'
require 'csv'
require 'string_to_pinyin'
require 'chinese/scraper'
require 'chinese/modules/options'
require 'chinese/core_ext/hash'
require 'chinese/core_ext/queue'

module Chinese
  class Vocab
    include Options

    attr_reader :words, :compact, :chinese, :not_found, :with_pinyin, :stored_sentences

    OPTIONS = {:compact      => [false, lambda {|value| is_boolean?(value) }],
               :with_pinyin  => [true,  lambda {|value| is_boolean?(value) }],
               :thread_count => [8,     lambda {|value| value.kind_of?(Integer) }]}


    def initialize(word_array, options={})
      # TODO: extend 'edit_vocab to also handle English text properly (e.g. remove 'somebody', 'someone', 'so', 'to do sth' etc)
      @compact = validate { :compact }
      @words    = edit_vocab(word_array)
      @words    = remove_redundant_single_char_words(@words)  if @compact
      @chinese  = is_unicode?(@words[0])
      @not_found        = []
      @stored_sentences = []
    end


    # Input:
    # path_to_csv: Path to CSV file
    # word_col   : Number of the word column we want to extract.
    # options    : Options used by the CSV class
    # Output:
    # Array of strings, where each string is a word from the CSV file.
    def self.parse_words(path_to_csv, word_col, options={})
      # Enforced options:
      # encoding: utf-8 (necessary for parsing Chinese characters)
      # skip_blanks: true
      options.merge!({:encoding => 'utf-8', :skip_blanks => true})
      csv = CSV.read(path_to_csv, options)

      raise ArgumentError, "Column number (#{word_col}) out of range."  unless within_range?(word_col, csv[0])
      # 'word_col counting starts at 1, but CSV.read returns an array,
      # where counting starts at 0.
      col = word_col-1
      csv.reduce([]) {|words, row|
        word = row[col]
        # If word_col contains no data, CSV::read returns nil.
        # We also want to skip empty strings or strings that only contain whitespace.
        words << word  unless word.nil? || word.strip.empty?
        words
      }
    end


    def sentences(options={})
      puts "Fetching sentences..."
      # Always run this method.
      @with_pinyin = validate { :with_pinyin }
      thread_count = validate { :thread_count }
      id           = make_hash(@words, @with_pinyin)

      from_queue  = Queue.new
      to_queue    = Queue.new
      file_name   = id

      if File.exist?(file_name)
        puts "examining file"
        words, sentences, not_found = File.open(file_name) { |f| f.readlines }
        @words = convert(words)
        convert(sentences).each { |s| to_queue << s }
        @not_found = convert(not_found)

        # Remove file
        File.unlink(file_name)
      end

      @words.each {|word| from_queue << word }
      result = []

      Thread.abort_on_exception = false

      1.upto(thread_count).map {
        Thread.new do

          while(word = from_queue.pop!) do
            count = 0

            begin
              local_result = select_sentence(word, options)
              puts "word: #{word}"
              # rescue SocketError, Timeout::Error, Errno::ETIMEDOUT,
              # Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError => e
            rescue Exception => e
              pause = 4
              puts " #{e.message}. Retry in #{pause} second(s)."
              sleep(pause)
              count -= 1
              retry  if count > 0

              raise
            # rescue Exception => e
            #   puts "I just catched exception: #{e}."
            #   raise
            ensure
              from_queue << word  if $!
            end


            to_queue << local_result  unless local_result.nil?

          end
        end
      }.each {|thread| thread.join }

      @stored_sentences = to_queue.to_a
      @stored_sentences
    ensure
      if $!
        sleep 7 # Give the threads enough time to put the word back to the queue.

        File.open(file_name, 'w') do |f|
          p "Writing to file..."
          f.write from_queue.to_a
          f.puts
          f.write to_queue.to_a
          f.puts
          f.write @not_found
        end
      end
    end


    # options - The Hash options used to refine the selection (default: {}):
    #           :color  - The String color to restrict by (optional).
    #           :weight - The Float weight to restrict by. The weight should
    #                     be specified in grams (optional).

    # Public: Select the minimum number of sentences necessary to cover all word characters.
    #
    # options - The Hash options used to refine the selection (default: {}):
    #           :with_pinyin - The Boolean to decide if the pinyin representation of a Chinese sentence
    #                          should be returned, too (default: true)
    #
    # Examples
    #
    #   min_sentenes(:pinyin => false)
    #   #
    #
    # Returns an Array of Hash objects
    def min_sentences(options = {})
      @with_pinyin = validate { :with_pinyin }
      # Always run this method.
      thread_count = validate { :thread_count }
      sentences    = sentences(options)

      puts "Calculating the minimum necessary sentences..."
      minimum_sentences = select_minimum_necessary_sentences(sentences)
      # :uwc = 'unique words count'
      with_uwc_tag      = add_key(minimum_sentences, :uwc) {|row| uwc_tag(row[:target_words]) }
      # :uws = 'unique words string'
      with_uwc_uws_tags = add_key(with_uwc_tag, :uws) do |row|
        words = row[:target_words].sort.join(', ')
        "[" + words + "]"
      end
      # Remove those keys we don't need anymore
      result            = remove_keys(with_uwc_uws_tags, :target_words, :word)
      @stored_sentences = result
      @stored_sentences
    end


    def sentences_unique_chars(sentences = stored_sentences)

      sentences.reduce([]) do |acc, row|
        acc = acc | row.scan(/\p{Word}/) # only return characters, skip punctuation marks
        acc
      end
    end


    def to_csv(path_to_file, options = {})

      CSV.open(path_to_file, "w", options) do |csv|
        @stored_sentences.each do |row|
          csv << row.values
        end
      end
    end


    # Helper functions
    # -----------------

    def remove_parens(word)
      # 1) Remove all ASCII parens and all data in between.
      # 2) Remove all Chinese parens and all data in between.
      word.gsub(/\(.*?\)/, '').gsub(/（.*?）/, '')
    end


    def is_boolean?(value)
      # Only true for either 'false' or 'true'
      !!value == value
    end


    # Remove all non-word characters
    def edit_vocab(word_array)
      puts "Editing vocabulary..."

      word_array.map {|word|
        edited = remove_parens(word)
        distinct_words(edited).join(' ')
      }.uniq
    end


    def make_hash(*data)
      require 'digest'
      data = data.reduce("") { |acc, item| acc << item.to_s }
      Digest::SHA2.hexdigest(data)[0..6]
    end


    # Input: ["看", "书", "看书"]
    # Output: ["看书"]
    def remove_redundant_single_char_words(words)
      puts "Removing redundant single character words from the vocabulary..."

      single_char_words, multi_char_words = words.partition {|word| word.length == 1 }
      return single_char_words  if multi_char_words.empty?

      non_redundant_single_char_words = single_char_words.reduce([]) do |acc, single_c|

        already_found = multi_char_words.find do |multi_c|
          multi_c.include?(single_c)
        end
        # Add single char word to array if it is not part of any of the multi char words.
        acc << single_c  unless already_found
        acc
      end

      non_redundant_single_char_words + multi_char_words
    end


    # Uses options passed from #sentences
    def select_sentence(word, options)
      sentence_pair = Scraper.sentence(word, options)

      # # If a word was not found, try again using the alternate download source:
      # alternate     = alternate_source(Scraper::Sources.keys, options[:source])
      # options       = options.merge(:source => alternate)
      # sentence_pair = Scraper.sentence(word, options)  if sentence_pair.empty?

      sources = Scraper::Sources.keys
      sentence_pair = try_alternate_download_sources(sources, word, options)  if sentence_pair.empty?

      if sentence_pair.empty?
        @not_found << word
        return nil
      else
        chinese, english = sentence_pair

        result = Hash.new
        result.merge!(word:    word)
        result.merge!(chinese: chinese)
        result.merge!(pinyin:  chinese.to_pinyin)  if @with_pinyin
        result.merge!(english: english)
      end
    end


    def try_alternate_download_sources(alternate_sources, word, options)
      sources = alternate_sources.dup
      sources.delete(options[:source])

      result = sources.find do |s|
        options  = options.merge(:source => s)
        sentence = Scraper.sentence(word, options)
        sentence.empty? ? nil : sentence
      end

      if result
        optins = options.merge(:source => result)
        Scraper.sentence(word, options)
      else
        []
      end
    end


    def convert(text)
      eval(text.chomp)
    end


    def add_target_words(hash_array)
      puts "Internal: Adding target words..."
      from_queue  = Queue.new
      to_queue    = Queue.new
      # semaphore = Mutex.new
      result      = []
      words       = @words
      hash_array.each {|hash| from_queue << hash}

      10.times.map {
        Thread.new(words) do

          while(row = from_queue.pop!)
            sentence     = row[:chinese]
            target_words = target_words_per_sentence(sentence, words)

            to_queue << row.merge(:target_words => target_words)

          end
        end
      }.map {|thread| thread.join}

      (to_queue.size).times { result << to_queue.pop }
      result
      # to_queue.to_a

    end


    def target_words_per_sentence(sentence, words)
       words.select {|w| include_every_char?(w, sentence) }
    end


    def sort_by_target_word_count(with_target_words)

      # First sort by size of unique word array (from large to short)
      # If the unique word count is equal, sort by the length of the sentence (from small to large)
      with_target_words.sort_by {|row|
        [-row[:target_words].size, row[:chinese].size] }

        #  The above is the same as:
        #   with_target_words.sort {|a,b|
        #     first = -(a[:target_words].size <=> b[:target_words].size)
        #     first.nonzero? || (a[:chinese].size <=> b[:chinese].size) }
    end


    def select_minimum_necessary_sentences(sentences)
      with_target_words = add_target_words(sentences)
      rows              = sort_by_target_word_count(with_target_words)

      selected_rows   = []
      unmatched_words = @words.dup
      matched_words   = []

      rows.each do |row|
        words = row[:target_words].dup
        # Delete all words from 'words' that have already been encoutered (and are included in 'matched_words').
        words = words - matched_words

        if words.size > 0  # Words that where not deleted above have to be part of 'unmatched_words'.
          selected_rows << row  # Select this row.

          # When a row is selected, its 'words' are no longer unmatched but matched.
          unmatched_words = unmatched_words - words
          matched_words   = matched_words + words
        end
      end
      selected_rows
    end


    def remove_keys(hash_array, *keys)
      hash_array.map { |row| row.delete_keys(*keys) }
    end


    def add_key(hash_array, key, &block)
      hash_array.map do |row|
        if block
          row.merge({key => block.call(row)})
        else
          row
        end
      end
    end


    def uwc_tag(string)
      size = string.length
      case size
      when 1
        "1_word"
      else
        "#{size}_words"
      end
    end


    def contains_all_target_words?(selected_rows, sentence_key)

      matched_words = @words.reduce([]) do |acc, word|

        result = selected_rows.find do |row|
          sentence = row[sentence_key]
          include_every_char?(word, sentence)
        end

        if result
          acc << word
        end

        acc
      end

      matched_words.size == @words.size
    end


    # def is_unicode?(word)
    #   puts "Unicode check..."
    #   # Remove all non-ascii and non-unicode word characters
    #   word = distinct_words(word).join
    #   # English text at this point only contains characters that are mathed by \w
    #   # Chinese text at this point contains mostly/only unicode word characters that are not matched by \w.
    #   # In case of Chinese text the size of 'char_arr' therefore has to be smaller than the size of 'word'
    #   char_arr = word.scan(/\w/)
    #   char_arr.size < word.size
    # end


    # Input:
    # column: word column number (counting from 1)
    # row   : Array of the processed CSV data that contains our word column.
    def self.within_range?(column, row)
      no_of_cols = row.size
      column >= 1 && column <= no_of_cols
    end


    def alternate_source(sources, selection)
      sources = sources.dup
      sources.delete(selection)
      sources.pop
    end


    # Return true if every distince word (as defined by #distinct_words)
    # can be found in the given sentence.
    def include_every_char?(word, sentence)
      characters = distinct_words(word)
      characters.all? {|char| sentence.include?(char) }
    end


    # # Input: "除了。。。 以外。。。"
    # # Outout: ["除了", "以外"]
    # def distinct_words(word)
    #   # http://stackoverflow.com/a/3976004
    #   # Alternative: /[[:word:]]+/
    #   word.scan(/\p{Word}+/)      # Returns an array of characters that belong together.
    # end

  end
end
