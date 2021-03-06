require_relative "../matchers/key_matchers"
require_relative "asn_standard_set_query_generator"
require_relative "query_to_standard_set"

# Converts files downloaded from the web and normalizes the keys
class ASNResourceParser

  def self.convert(hash)
    new_hash = hash.reduce({
      "_id" => "",
      "documentMeta" => {},
      "document" => {},
      "standards" => {},
    }) do |memo, tuple|
      case tuple[0]
      when /^http\:\/\/asn\.(?:desire2learn\.com|jesandco\.org)\/resources\/(D[a-zA-Z0-9]*)(\.xml)/
        memo["documentMeta"] = self.convert_hash(tuple[1])
      when /^http\:\/\/asn\.(?:desire2learn\.com|jesandco\.org)\/resources\/(D[a-zA-Z0-9]*)$/
        memo["document"] = self.convert_hash(tuple[1])
      when /^http\:\/\/asn\.(?:desire2learn\.com|jesandco\.org)\/resources\/(S[a-zA-Z0-9]*)$/
        new_value = self.convert_hash(tuple[1])
        new_value["asnIdentifier"] = $1
        memo["standards"][$1] = new_value
      end
      memo
    end
    new_hash["standardSetQueries"] = ASNStandardSetQueryGenerator.generate(new_hash)
    new_hash["_id"] = new_hash["documentMeta"]["primaryTopic"]
    new_hash
  end


  def self.convert_hash(hash)
    # Tuple has the form [key, value]
    new_hash = hash.reduce({}) do |memo, tuple|

      matcher = KEY_MATCHERS[tuple[0]]

      if !matcher.nil?
        matcher.call(tuple[0], tuple[1]).each do |ret_key,ret_value|
          memo[ret_key.to_s] = ret_value
        end
      else
        memo[tuple[0]] = tuple[1]
      end

      memo
    end

    return new_hash
  end


end
