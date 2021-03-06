module Glove
  class Model
    # Default options (see #initialize)
    DEFAULTS = {
      max_count:      100,
      learning_rate:  0.05,
      alpha:          0.75,
      num_components: 30,
      epochs:         5,
      threads:        4
    }

    # @!attribute [r] corpus
    #   @return [Glove::Corpus] reference to the Corpus instance
    # @!attribute [r] token_index
    #   @return [Hash] reference to corpus.index
    # @!attribute [r] token_pairs
    #   @return [Array<(Glove::TokenPair)>] reference to corpus.pairs
    # @!attribute [rw] word_vec
    #   @return [GSL::Matrix] the word vector matrix
    # @!attribute [rw] word_biases
    #   @return [GSL::Vector] the vector holding the word biases
    attr_reader :opts, :window, :epochs, :num_components, :min_count
    attr_reader :learning_rate, :alpha, :max_count, :threads
    attr_reader :cooc_matrix, :corpus, :token_index, :token_pairs
    attr_accessor :word_vec, :word_biases

    # Create a new {Glove::Model} instance. Accepts options for
    # {Glove::Corpus} and {Glove::Parser} which only get forwarded
    # and not used in this class.
    #
    # @param [Hash] options the options to initialize the instance with.
    # @option options [Integer] :max_count (100) Parameter specifying cutoff in
    #   weighting function
    # @option options [Float] :learning_rate (0.05) Initial learning rate
    # @option options [Float] :alpha (0.75) Exponent of weighting function
    # @option options [Integer] :num_components (30) Column size of the word vector
    #   matrix
    # @option options [Integer] :epochs (5) Number of training iterations
    # @option options [Integer] :threads (4) Number of threads to use in building
    #   the co-occurence matrix and training iterations. Must be greater then 0
    # @return [Glove::Model] A GloVe model.
    def initialize(options={})
      @opts = DEFAULTS.dup.merge(options)
      @opts.each do |key, value|
        instance_variable_set :"@#{key}", value
      end

      @cooc_matrix = nil
      @word_vec    = nil
      @word_biases = nil
    end

    # Fit a string or {Glove::Corpus} instance and build co-occurance matrix
    #
    # @param [String, Glove::Corpus] text The text to train from
    # @example Provide corpus for the model
    #   model = Glove::Model.new
    #   model.fit(File.read('shakespeare.txt'))
    # @example Provide a {Glove::Corpus} instance as text argument
    #   model = Glove::Model.new
    #   corpus = Glove::Corpus.build(File.read('shakespeare.txt'))
    #   model.fit(corpus)
    # @return [Glove::Model] Current instance
    def fit(text)
      fit_corpus(text)
      build_cooc_matrix
      build_word_vectors
      self
    end

    # Train the model. Must call #fit prior
    # @return [Glove::Model] Current instance
    def train
      train_in_epochs(matrix_nnz)
      self
    end

    # Save trained data to files
    #
    # @param [String] corpus_file Filename for corpus
    # @param [String] cooc_file Filename for co-occurence matrix
    # @param [String] vec_file Filename for Word Vector Maxtrix
    # @param [String] bias_file Filename for Word Biases Vector
    def save(corpus_file, cooc_file, vec_file, bias_file)
      File.open(corpus_file, 'wb') do |file|
        file.write Marshal.dump(corpus)
      end

      cooc_matrix.fwrite(cooc_file)
      word_vec.fwrite(vec_file)
      word_biases.fwrite(bias_file)
    end

    # Loads training data from already existing files
    #
    # @param [String] corpus_file Filename for corpus
    # @param [String] cooc_file Filename for co-occurence matrix
    # @param [String] vec_file Filename for Word Vector Maxtrix
    # @param [String] bias_file Filename for Word Biases Vector
    def load(corpus_file, cooc_file, vec_file, bias_file)
      @corpus = Marshal.load(File.binread(corpus_file))

      @token_index = corpus.index
      @token_pairs = corpus.pairs

      size = token_index.size

      @cooc_matrix = GSL::Matrix.alloc(size, size)
      @word_vec    = GSL::Matrix.alloc(size, num_components)
      @word_biases = GSL::Vector.alloc(size)

      @cooc_matrix.fread(cooc_file)
      @word_vec.fread(vec_file)
      @word_biases.fread(bias_file)
    end

    # @todo create graph of the word vector matrix
    def visualize
      raise "Not implemented"
    end

    # Get a words that relates to :target like :word1 relates to :word2
    #
    # @param [String] word1
    # @param [String] word2
    # @param [Integer] num Number of related words to :target
    # @param [Float] accuracy Allowance in difference of target cosine
    #   and related word cosine distances
    # @example What words relate to atom like quantum relates to physics?
    #   model.analogy_words('quantum', 'physics', 'atom')
    #   # => [["electron", 0.98583], ["energi", 0.98151], ["photon",0.96650]]
    # @return [Array] List of related words to target
    def analogy_words(word1, word2, target, num=3, accuracy=0.0001)
      word1  = word1.stem
      word2  = word1.stem
      target = target.stem

      distance = cosine(vector(word1), vector(word2))

      vector_distance(target).reject do |item|
        diff = item[1].to_f.abs - distance
        diff.abs < accuracy
      end.take(num)
    end

    # Get most similar words to :word
    #
    # @param [String] word The word to find similar to
    # @param [Integer] num (3) Number of similar words to :word
    # @example Get 1 most similar word to 'physics'
    #   model.most_similar('physics', 1) # => ["quantum", 0.9967993356234444]
    # @return [Array] List of most similar words with cosine distance as values
    def most_similar(word, num=3)
      vector_distance(word.stem).take(num)
    end

    # Prevent token_pairs, matrices and vectors to fill up the terminal
    def inspect
      to_s
    end

    private

    # Perform train iterations
    #
    # @param [Array] indices The non-zero value indices in cooc_matrix
    def train_in_epochs(indices)
      1.upto(epochs) do |epoch|
        shuffled = indices.shuffle
        @word_vec, @word_biases = Workers::TrainingWorker.new(self, shuffled).run
      end
    end

    # Builds the corpus and sets @token_index and @token_pairs
    def fit_corpus(text)
      @corpus =
        if text.is_a? Corpus
          text
        else
          Corpus.build(text, opts)
        end

      @token_index = corpus.index
      @token_pairs = corpus.pairs
    end

    # Create initial values for @word_vec and @word_biases
    def build_word_vectors
      cols          = token_index.size
      @word_vec     = GSL::Matrix.rand(cols, num_components)
      @word_biases  = GSL::Vector.alloc(cols)
    end

    # Buids the co-occurence matrix
    def build_cooc_matrix
      @cooc_matrix = Workers::CooccurrenceWorker.new(self).run
    end

    # Array of all non-zero (both row and col) value coordinates in the
    # cooc_matrix
    def matrix_nnz
      entries = []
      cooc_matrix.enum_for(:each_col).each_with_index do |col, col_idx|
        col.enum_for(:each).each_with_index do |row, row_idx|
          value = cooc_matrix[row_idx, col_idx]

          entries << [row_idx, col_idx] unless value.zero?
        end
      end
      entries
    end

    # Find the vector row of @word_vec for a given word
    #
    # @param [String] word The word to transform into a vector
    # @return [GSL::Vector] The corresponding vector into the #word_vec matrix
    def vector(word)
      return nil unless word_index = token_index[word]
      word_vec.row(word_index)
    end

    # Balculates the cosine distance of all the words in the vocabulary
    # against a given word. Results are then sorted in DESC order
    #
    # @param [String] word The word to compare against
    # @return [Array<(String, Integer)>] Array of tokens and their distance
    def vector_distance(word)
      return {} unless word_vector = vector(word)

      token_index.map.with_index do |(token,count), idx|
        next if token.eql? word
        [token, cosine(word_vector, word_vec.row(idx))]
      end.compact.sort{ |a,b| b[1] <=> a[1] }
    end

    # Compute cosine distance between two vectors
    #
    # @param [GSL::Vector] vector1 First vector
    # @param [GSL::Vector] vector2 Second vector
    # @return [Float] the cosine distance
    def cosine(vector1, vector2)
      return 0 if vector1.nil? || vector2.nil?
      vector1.dot(vector2) / (vector1.norm * vector2.norm)
    end
  end
end
