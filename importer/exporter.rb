require 'bundler/setup'
require 'oj'
require 'pp'
require 'date'
require 'time'
require 'parallel'
require 'csv'
require 'carmen'
require_relative '../config/mongo'

class Exporter
  def self.run
    @united_states = Carmen::Country.named('United States')

    out_file = File.open("common_curriculum_standards.csv", 'w+')
    out_file.puts headers
    $db[:standard_documents].find({}).each do |doc|
      begin
        doc_to_lines(doc) do |line|
          out_file.puts CSV.generate_line(line)
        end
      rescue
        puts "FAILED DOC", pp(doc)
        raise
      end
    end
  end

  def self.headers
    CSV.generate_line([
      'Standards Family',
      'Subject',
      'Strand Category',
      'Strand Name',
      'Standard Label',
      'Standard Text',
      'Grade','Country',
      'State',
      'Common Core?',
      'State Standard?',
      'Year',
      'Source Data'
    ])
  end

  def self.doc_to_lines(doc)
    all_nodes = []
    grandparents = []
    parents = []
    children = []

    doc['standards'].each do |id, standard|
      if is_child(standard)
        children << standard
      end

      all_nodes << standard
    end

    children.each do |child|
      parent      = parent_of(child, all_nodes)
      grandparent = parent_of(parent, all_nodes)

      # Hack for 2-tier standards using "[Strand Category]: [Strand Name]" format
      if grandparent.nil? and is_grandparent(parent) and parent['description'].include? ": "
        grandparent = parent.dup
        parent      = {}
        grandparent['description'], parent['description'] = grandparent['description'].split(': ')
      end

      # Given only one parent, opt for grandparent (opts to have Strand Category over Strand Name)
      if grandparent.nil? and is_grandparent(parent)
        grandparent = parent.dup
        parent      = {'description' => ''}
      end

      edu_levels_to_grade(child['educationLevels']) do |grade|
        puts "BROKEN HOME", child.inspect, parent.inspect, grandparent.inspect unless child and parent and grandparent
        line        = family_to_line(doc['document'], grade, child, parent, grandparent)
        yield line
      end
    end
  end

  def self.edu_levels_to_grade(levels_arr)
    sorted = levels_arr.uniq.sort

    if sorted == ['09','10','11','12']
      yield 'HS'
    elsif sorted == ['06','07','08']
      yield 'MS'
    else
      sorted.map{|g| (if g.to_i>0 then g.to_i else g end).to_s }.each{|g| yield g }
    end
  end

  private

  def self.family_to_line(document, grade, child, parent, grandparent)
    maybe_state = document['jurisdictionTitle']

    [
      document['title'],                        # Standards Family
      document['subject'],                      # Subject

      grandparent['description'],               # Strand Category
      parent['description'],                    # Strand Name

      child['statementNotation'],               # Label
      child['description'],                     # Text

      grade,                                    # Grade
      state_to_country(maybe_state),            # Country (US, or add manually later)
      state_to_state_abbr(maybe_state),         # State
      "",                                       # Common Core? (Add manually, later)
      state_to_state_standard?(maybe_state),    # State Standard?
      document['valid'],                        # Year
      document['source']
    ]
  end

  def self.state_to_country(state)
    if state and (state_obj = @united_states.subregions.named(state))
      "United States"
    else
      ""
    end
  end

  def self.state_to_state_abbr(state)
    if state and (state_obj = @united_states.subregions.named(state))
      state_obj.code
    else
      ""
    end
  end

  def self.state_to_state_standard?(state)
    unless state.blank? then "Yes" else "No" end
  end

  def self.parent_of(child, possible_parents)
    possible_parents.find do |parent|
      child['isChildOf'] == parent['asnIdentifier']
    end
  end

  def self.is_grandparent(standard)
    keys = standard.keys

    [
      (standard['isPartOf'] == standard['isChildOf']),
      (standard['isChildOf'][0] == "D"),
      (keys.include?('children'))
    ].all?
  end

  # def self.is_parent(standard)
  #   keys = standard.keys

  #   [
  #     (standard['isPartOf'] != standard['isChildOf']),
  #     (keys.include?('isPartOf')),
  #     (keys.include?('isChildOf')),
  #     (!keys.include?('statementNotation'))
  #   ].all?
  # end

  def self.is_child(standard)
    keys = standard.keys

    [
      (standard['isPartOf'] != standard['isChildOf']),
      (keys.include?('isPartOf')),
      (keys.include?('isChildOf')),
      (keys.include?('statementNotation')),
      (!keys.include?('children')),
    ].all?
  end
end
