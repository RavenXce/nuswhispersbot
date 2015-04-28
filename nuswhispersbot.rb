require 'fb_graph'
require 'redis'
require 'open-uri'
require 'json'

class NusWhispersBot

  REDIS_KEY = ENV['REDIS_KEY'] || 'nwb_last_ran_timestamp'
  ACCESS_TOKEN  = ENV['PAGE_ACCESS_TOKEN']
  MAX_FETCH = ENV['MAX_FETCH'] || 250
  HASHTAG_REGEX = /#[[:alnum:]_]+/
  NUMERIC_TAG_REGEX = /\d+$/

  def redis
    @_redis ||= Redis.new
  end

  def whispers_page
    @whispers_page ||= FbGraph::Page.fetch('nuswhispers', access_token: ACCESS_TOKEN)
  end

  def bot_page
    @_bot_page ||= FbGraph::Page.fetch('nuswhispersbot', access_token: ACCESS_TOKEN)
  end

  def parse_post(post)

    content, footer = post.message.split(/\n-\n #/)

    if content && footer
      hashtags = content.scan(HASHTAG_REGEX)

      results = hashtags.map do |tag|
        tag[0] = '' # remove hash (#) character

        if tag.match(NUMERIC_TAG_REGEX)

          begin
            open("http://nuswhispers.com/api/confessions/#{tag}") do |f|
              json = JSON.parse(f.read)
              if json['success'] == false
                { type: 'tag', tag: tag, link: "http://nuswhispers.com/tag/#{tag}" }
              elsif json['success'] == true
                { type: 'confession', tag: tag, link: "http://nuswhispers.com/confessions/#{tag}", content: json['data']['confession']['content'] }
              else
                { type: 'invalid', reason: 'Could not find success code.' }
              end
            end
          rescue => e
            { type: 'invalid', reason: 'Could not parse JSON.' }
          end

        else
          { type: 'tag', tag: tag, link: "http://nuswhispers.com/tag/#{tag}" }
        end

      end

      results = results.group_by { |x| x[:type] }

      comment = ""
      if results['confession']
        comment << "\nThe following confessions were referenced in this post:\n=="
        results['confession'].each do |r|
          comment << "\n\##{r[:tag]}: #{r[:content]}\n-- Original link: #{r[:link]}\n"
        end
        comment << "\n"
      end
      if results['tag']
        comment << "\nThe following tags were found in this post:\n=="
        results['tag'].each do |r|
          comment << "\n\##{r[:tag]}: #{r[:link]}"
        end
        comment << "\n==\n"
      end
      unless comment.empty?
        comment << "For queries, complains, bug reports: nuswhispersbot@gmail.com"
        post.comment!(message: comment)
        puts "Commented on post #{post.identifier}."
      end

    end

  end


  def run
    last_ran_timestamp = redis.get(REDIS_KEY) || (Time.now - 1.month).to_i
    current_timestamp = Time.now.utc.to_i
    posts = whispers_page.posts(limit: MAX_FETCH, since: last_ran_timestamp)

    puts "Parsing #{posts.count} posts from #{last_ran_timestamp}.."
    posts.each do |post|
      parse_post(post)
    end
  ensure
    redis.set(REDIS_KEY, current_timestamp)
  end

end

NusWhispersBot.new.run
