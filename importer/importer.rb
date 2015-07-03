# The part that activates bundler in your app
require 'bundler/setup'
require 'oj'
require 'pp'
require 'date'
require 'time'
require 'typhoeus'
require 'parallel'
require_relative 'matchers/source_to_subject_mapping'
require_relative 'transformers/asn_resource_parser'
require_relative "update_standard_set"
require 'mongo'

logger = Logger.new(STDOUT)
logger.level = Logger::WARN
Mongo::Logger.logger = logger

docs  = Oj.load(File.read('sources/asn_standard_documents_july-2.js'))
$db   = Mongo::Client.new([ '127.0.0.1:27017' ], :database => 'standards')
hydra = Typhoeus::Hydra.new(max_concurrency: 20)


# ===================================================
# Section 1: Functions for conversion
# Because of how Ruby loads method names, the methods
# that the script uses go at the top
# ===================================================

def check_document_titles(docs)
  -> {
    titles_to_be_edited =  docs["documents"].reduce({}){|acc, doc|
      subject = SOURCE_TO_SUBJECT_MAPPINGS[doc["data"]["title"][0]]
      if subject.nil?
        acc[doc["data"]["title"][0]] = doc["data"]["title"][0]
      else
        acc
      end
      acc
    }

    # Notify if we don't have all the right titles
    if titles_to_be_edited.keys.length > 0
      puts ""
      pp titles_to_be_edited
      puts ""
      raise "You must add these subjects before you continue"
    end
  }
end


# Here, we're just parsing the JSON into an easier to use format for the rest of the scripts
def parse_doc_json(docs)
  find_id = lambda{ |title| $db[:jurisdictions].find({title: title}).to_a.first[:_id]}
  docs["documents"].map{|doc|
    {
      date_modified:   doc["data"]["date_modified"][0],
      date_valid:      doc["data"]["date_valid"][0],
      description:     doc["data"]["description"][0],
      id:              doc["id"].upcase,
      jurisdiction:    doc["data"]["jurisdiction"][0],
      jurisdiction_id: find_id.call(doc["data"]["jurisdiction"][0]),
      subject:         SOURCE_TO_SUBJECT_MAPPINGS[doc["data"]["title"][0]],
      title:           doc["data"]["title"][0],
      url:             doc["data"]["identifier"][0],
    }
  }
end


# There's an odd difference between the modified timestamp
# on the JSON we download and the modified timestamp we get from the API
# (haven't tried the RSS feed yet). I'm guessing this is because they're
# separate systems and the mark modified when they import it into their
# search service. The time delay isn't due to timezone differences as it's
# often 2-6 days didfferent.
def set_retrieved(doc, request, modified)
  doc["retrieved"] = {
    from:                      request.url,
    at:                        Time.now,
    modifiedAccordingToASNApi: modified
  }
  doc
end

def save_standard_document(doc)
  $db[:standard_documents].find({_id: doc["_id"]}).find_one_and_update(doc, {upsert: true, return_document: :after})
end


def generate_standard_sets(doc)
  Parallel.each(doc["standardSetQueries"], :in_processes => 16){|query|
    p "Converting #{doc["document"]["title"]}: #{query["title"]}"
    set = QueryToStandardSet.generate(doc, query)
    UpdateStandardSet.update(set)
    Parallel::Kill
  }
  doc
end

def update_jurisdiction(doc)
  # We add the document to the jurisdiction so that we have can easily have a count
  # of how mnay documents a jurisdiction has
  $db[:jurisdictions].find({_id: doc["document"]["jurisdictionId"]}).update_one({
    :$addToSet => {:cachedDocumentIds => doc["_id"]}
  })
end

# See commnet on set_retrieved
def get_previously_imported_docs
  $db[:standard_documents].find()
    .projection({"documentMeta.primaryTopic" => 1, "retrieved.modifiedAccordingToASNApi" => 1, "_id" => 1})
    .to_a
    .reduce({}){|memo, d|
      memo.merge({
        d["documentMeta"]["primaryTopic"] => d["retrieved"]["modifiedAccordingToASNApi"]
      })
    }
end

def rescue_exception(e, doc)
  puts "EXCEPTION"
  puts e.message
  puts e.backtrace.inspect
  pp doc
end



# ===================================================
# Section 2: The conversion
# This script that makes the requests and converts each
# document.
# ===================================================

# Check that we have all the right titles
check_document_titles(docs)
docs = parse_doc_json(docs)

previously_imported_docs = get_previously_imported_docs

docs.select{|doc|
  # This makes sure we only get the documents we haven't already imported.
  # Return true from this labmda if we want to fetch all the docs.
  Time.at(previously_imported_docs[doc[:id]].to_i) < Time.at(doc[:date_modified].to_i)
}.each.with_index{ |_doc, index|

  # If we want to use the ASN urls, uncomment this line. I switched to using AWS urls to relieve load on ASN
  # servers and increase thoroughput
  # request = Typhoeus::Request.new(doc[:url] + "_full.json", followlocation: true)
  request = Typhoeus::Request.new("http://s3.amazonaws.com/asnstaticd2l/data/rdf/" + _doc[:id].upcase + ".json", followlocation: true)
  request.on_complete do |response|
    begin
      p "#{index + 1}. Converting: #{request.url}"
      doc = ASNResourceParser.convert(Oj.load(response.body))
      doc = set_retrieved(doc, request, _doc[:date_modified])
      doc = save_standard_document(doc)
      doc = generate_standard_sets(doc)
      update_jurisdiction(doc)

    rescue Exception => e
      rescue_exception(e, doc)
    end
  end
  hydra.queue(request)
}

hydra.run
