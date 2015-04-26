require 'fb_graph'
require 'open-uri'
require 'json'

class NusWhispersBot

  ACCESS_TOKEN  = ENV['PAGE_ACCESS_TOKEN']
  HASHTAG_REGEX = /#[[:alnum:]_]+/
  NUMERIC_TAG_REGEX = /\d+$/
  MAX_FETCH = 5

  def whispers_page
    @whispers_page ||= FbGraph::Page.fetch('nuswhispers', access_token: ACCESS_TOKEN)
  end

  def bot_page
    @_bot_page ||= FbGraph::Page.fetch('nuswhispersbot', access_token: ACCESS_TOKEN)
  end

  def parse_post(post)

    content, footer = post.split(/\n-\n #/) #'#1234 #1217 #tag #abc', 'a'

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

      post = ""
      if results['confession']
        post << "\nThe following confessions were referenced in this post:\n=="
        results['confession'].each do |r|
          post << "\n\##{r[:tag]}: #{r[:content]}\n-- Original link: #{r[:link]}\n"
        end
        post << "\n"
      end
      if results['tag']
        post << "\nThe following tags were found in this post:\n=="
        results['tag'].each do |r|
          post << "\n\##{r[:tag]}: #{r[:link]}"
        end
        post << "\n==\n"
      end
      unless post.empty?
        post << "For queries, complains, bug reports: nuswhispersbot@gmail.com"
        bot_page.posts.first.comment!(message: post)
      end

    end

  end


  def run
    posts = whispers_page.posts(limit: MAX_FETCH)

    puts "Parsing #{posts.count} posts.."
    posts.each do |post|
      parse_post(post.message)
    end
  end

end

NusWhispersBot.new.run
