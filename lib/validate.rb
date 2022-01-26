require 'yaml'
require './lib/common'

# @todo Acronyms must reference a term
# @todo Cross-references are set as arrays
# @todo Cross-references are always terms

# Validates an entire glossary file
class GlossaryValidator

  include Common

  attr_reader :data, :key

  # @param path [String | nil] path to glossary file
  def initialize(path: nil)
    @path = path || './glossary.yml'
    @key = :entries
    @data = symbolize_keys(YAML.load_file(@path))
    # Minimally assert that the key is present
    # @todo: Make a better error message
    @data.fetch(@key)
  end

  # Validate all entries
  def perform
    validator = EntryValidator.new(data[key])
    data[key].each do |entry|
      validator.validate([entry].to_h)
    end
  ensure
    # Regardless of errors, show the reminders
    if validator.reminders.any?
      puts "\nReminders:"
      puts "----------\n"
      validator.reminders.each { |r| puts "- #{r}"}
      puts "\n"
    end
  end

end


# Validates an entry. Needs the entire glossary file to work,
# as it needs to determine whether linked terms are present.
class EntryValidator

  @@type_entry = [:term, :acronym]

  attr_reader :context
  attr_accessor :reminders

  # @param context [Hash] all glossary entries - everything under the top-level key
  def initialize(context)
    @context = context
    @reminders = []
  end

  # @param data [Hash] data for a single entry
  def validate(data)
    raise ArgumentError if (data.keys.count > 1)
    key = data.keys.first
    values = data.values.first
    case values[:type]
    when "term" then
      validate_term(data)
    when "acronym" then
      validate_acronym(data)
    else
      raise EntryTypeError.new(key)
    end
  end

  # Validates a term. At present it:
  #   - ensures that it has a `description` key (with content or an explicit `nil`)
  #   - ensures that all cross-referenced terms are present in the glossary
  #   - asserts that there are no extra keys for the entry
  #
  # @param term_data [Hash] data for a single entry of type 'term'
  def validate_term(term_data)
    key = term_data.keys.first
    values = term_data.values.first

    unless values.has_key?(:description)
      raise TermMissingDescriptionError.new(key)
    end

    desc = values[:description]
    if desc.nil?
      reminders << "add a description for \"#{values[:longform] || key}\""
    elsif desc.is_a?(String) && !desc.empty?
      # NO OP
    else
      raise TermMissingDescriptionError.new(key)
    end

    Array(values[:cross_references]).each do |crossref|
      context.fetch(crossref.to_sym) {
        raise TermNotFoundError.new(key, crossref, true)
      }
    end

    assert_no_extra_keys(
      key,
      values,
      [ :type,
        :description,
        :longform,
        :cross_references
      ]
    )
    return true
  end

  # Validates an acronym. At present it:
  # @todo keep going on this documentation
  def validate_acronym(acronym_data)
    key = acronym_data.keys.first
    values = acronym_data.values.first

    # term defined
    case values[:term].class.to_s
    when "String" then
      check_term_defined(values[:term])
    when "Array" then
      check_term_defined(values[:term])
    when "NilClass" then
      raise MissingTermError.new(key)
    else
      raise MissingTermError.new(key)
    end

    # term is in the glossary
    terms = Array(values[:term])
    terms.each do |term|
      # puts term.to_sym.inspect
      # puts context.inspect
      unless context[term.to_sym]
        raise TermNotFoundError.new(key, term)
      end

      unless context[term.to_sym][:type] == "term"
        raise AcronymReferenceError.new(key, term)
      end
    end

    # make sure there are no extra keys
    assert_no_extra_keys(key, values, [:term, :type])

    return true
  end

  def check_term_defined(term)
    if term.empty?
      MissingTermError.new(key)
    else
      return true
    end
  end

  def assert_no_extra_keys(key, value_set, only_allow=[])
    keychain = value_set.keys
    only_allow.each { |key| keychain.delete(key) }
    unless keychain.empty?
      raise BadSchemaError.new(key, keychain)
    end
  end

end

class MissingTermError < StandardError
  attr_reader :key, :term

  def initialize(key)
    @key = key
    @term = key.to_s.split('').map { |letter| "#{letter}____ "}.join()
    super(message)
  end

  def message
    <<~ERR


      The acronym \"#{key}\" doesn't define a related term!

      How can a reader know what your acronym means?

      If you think you added a term, maybe there's a typo somewhere.

      If you haven't added a term, add one like this:

          #{key}:
            type: acronym
            term: #{term}

          ... later on ...

          #{term}:
            type: term
            description: |
              You write out what this term means.
    ERR
  end
end

class TermNotFoundError < StandardError
  attr_reader :key, :missing_term, :crossref

  def initialize(key, missing_term, crossref=false)
    @key = key
    @missing_term = missing_term
    @crossref = crossref
    super(message)
  end

  def message
    noun = crossref ? "term" : "acronym"
    verbs = crossref ? "cross-references" : "defines"
    <<~ERR


      The #{noun} \"#{key}\" #{verbs} the term \"#{missing_term}\",
      but I cannot find that term anywhere in the glossary.

      How can I know what term to link to?

      Add an entry for \"#{missing_term}\", like:

          #{missing_term}:
            type: term
            description: |
              You explain what the term means.
            cross_references:
              - Terms that are related
              - to this one.
    ERR
  end
end

class TermMissingDescriptionError < StandardError
  attr_reader :key

  def initialize(key)
    @key = key
    super(message)
  end

  def message
    <<~ERR


      The term \"#{key}\" does not have a description.

      How can a reader know what this term means?

      Add a description! Like this:

          #{key}
            type: term
            description: |
              You explain what the term means.

      If want to temporarily skip adding a description, you can specify it like this:

          #{key}
              type: term
              description: null

      I'll remind you about it later.
    ERR
  end
end

class BadSchemaError < StandardError
  attr_reader :key, :extra_keys

  def initialize(key, extra_keys)
    @key = key
    @extra_keys = extra_keys
    super(message)
  end

  def message
    <<~ERR


      Your entry \"#{key}\" defines the following attributes (a.k.a. "keys"):

        #{extra_keys.join(", ")}

      These attributes aren't needed. Please delete them!
    ERR
  end
end

class AcronymReferenceError < StandardError
  attr_reader :key, :points_to

  def initialize(key, points_to)
    @key = key
    @points_to = points_to
    super(message)
  end

  def message
    <<~ERR


      Your acronym "#{key}" refers to another acronym: \"#{points_to}\".

      That doesn't make sense to me!

      Please link your acronym to an entry that has a type of \"term\". Like this:

      #{key}:
        type: acronym
        term: #{points_to}

      #{points_to}:
        type: term
        description: |
          You explain what the term means.
    ERR
  end

end

class EntryTypeError < StandardError
  attr_reader :key

  def initialize(key)
    @key = key
    super(message)
  end

  def probable_type
    key_str = key.to_s
    # If it's all uppercase and shorter than 10 characters,
    # it's probably an acronym
    if (key_str <=> key_str.upcase) == 0 && key_str.length < 10
      return "acronym"
    else
      return "term"
    end
  rescue => e
    # Ignore all errors and default to "term" if there's an issue.
    "term"
  end

  def message
    <<~ERR


      Your entry "#{key}" does not have a type.

      I need to know whether it is an "acronym" or a "term".

      My best guess is that it is a "#{probable_type}", but I'm not sure.

      Please add a 'type' key to your entry, with one of those values. Like this:

      #{key}:
        type: #{probable_type}
    ERR
  end
end
