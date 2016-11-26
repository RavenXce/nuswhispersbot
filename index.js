'use strict';
console.log('Loading function');

let aws = require('aws-sdk');
let graph = require('fbgraph');
let request = require('request');
let async = require('async');
let _ = require('underscore');

let MAX_FETCH = 100;
let MAX_COMMENT_LENGTH = 8000;
let HASHTAG_REGEX = /#\w+/g;
let NUMERIC_TAG_REGEX = /\d+$/g;

String.prototype.scan = function (re) {
  if (!re.global) throw "Regex needs to have global flag set";
  var s = this;
  var m, r = [];
  while (m = re.exec(s)) {
    r.push(m[0]);
  }
  return r;
};

exports.handler = (event, context, callback) => {
  // console.log('Received event:', JSON.stringify(event, null, 2));

  // Load credentials from environment
  let fb_access_token = process.env.FB_ACCESS_TOKEN;

  // Load metadata from s3
  let s3 = new aws.S3({ apiVersion: '2006-03-01', params: { Bucket: 'nuswhispersbot' } });
  let s3_objects = [{ Key: 'last_ran_timestamp' }];

  async.map(s3_objects, s3.getObject.bind(s3), (err, data) => {
    if (err) {
      console.error(err);
      callback(`Error loading data from S3: ${err}`);
      return;
    }

    let last_ran_timestamp = parseInt(data[0].Body.toString().trim());
    let timestamp_now = Math.floor(Date.now() / 1000);

    // get latest posts
    graph.setAccessToken(fb_access_token);
    graph.get('nuswhispers/feed', { limit: MAX_FETCH, since: last_ran_timestamp }, (err, res) => {
      if (err) {
        console.error(err);
        callback(`Error getting facebook feed: ${err}`);
        return;
      }

      // update the timestamp first
      s3.upload({ Key: 'last_ran_timestamp', Body: String(timestamp_now) }, (err) => {
        if (err) {
          console.error(err);
          callback(`Error updating timestamp: ${err}`);
          return;
        }
      });

      // parse & comment on posts
      let posts = res.data;
      console.info(`Parsing ${posts.length} posts from ${last_ran_timestamp}`);
      async.each(posts, parseAndCommentOnPost, (err, res) => {
        if (err) {
          console.error(err);
          callback(`Error posting comments: ${err}`);
        } else {
          callback(null, `Done comment function at: ${timestamp_now}`);
        }
      });
    });
  });
}

function parseAndCommentOnPost(post, callback) {
  let post_parts = post.message.split(/\n-\n#/)
  if (post_parts.length != 2) return;

  let content = post_parts[0];
  let hashtags = _.unique(content.scan(HASHTAG_REGEX));

  if (hashtags.length > 0) console.info(`Found hashtags: ${hashtags}`);

  // note: limit to checking 3 tags at once to prevent spamming nuswhispers.com
  async.mapLimit(hashtags, 3, checkTag, (error, results) => {
    results = _.groupBy(results, 'type');
    var comment = generateComment(results);
    if (comment.length > 0) {
      comment += "For queries, complains, bug reports: nuswhispersbot@gmail.com";
      // comment!
      console.info(`Commenting on post: ${post.id}`);
      graph.post(`${post.id}/comments`, { message: comment }, callback);
    } else {
      callback(null, null);
    }
  })
}

function checkTag(tag, callback) {
  tag = tag.substring(1); // remove hash (#) character
  if (tag.match(NUMERIC_TAG_REGEX)) {
    request(`https://nuswhispers.com/api/confessions/${tag}`, (error, response, body) => {
      let json = JSON.parse(body);
      if (json.success == false) {
        callback(null, { type: 'tag', tag: tag, link: `https://nuswhispers.com/tag/${tag}` });
      } else if (json.success == true) {
        callback(null, {
          type: 'confession',
          tag: tag,
          link: `https://nuswhispers.com/confession/${tag}`,
          fb_link: `https://www.facebook.com/nuswhispers/posts/${json.data.confession.fb_post_id}`,
          content: json.data.confession.content
        });
      } else {
        callback(null, { type: 'invalid', reason: 'Could not find success code.' });
      }
    });
  } else {
    callback(null, { type: 'tag', tag: tag, link: `https://nuswhispers.com/tag/${tag}` });
  }
}

function generateComment(results, max_post_length) {
  if (!max_post_length) max_post_length = MAX_COMMENT_LENGTH;

  var comment = "";

  if (results.confession) {
    comment += "\nThe following confessions were referenced in this post:\n==";
    results.confession.forEach((r) => {
      if (r.content > max_post_length) {
        r.content = "Post too long to display. Please use below links.";
      }
      comment += `\n\#${r.tag}: ${r.content}\n-- Original link: ${r.link}\n-- Facebook link: ${r.fb_link}\n`;
    });
    comment += "\n";
  }

  if (results.tag) {
    comment += "\nThe following tags were found in this post:\n==";
    results.tag.forEach((r) => {
      comment += `\n\#${r.tag}: ${r.link}`;
    });
    comment += "\n==\n";
  }

  if (comment.length > MAX_COMMENT_LENGTH && max_post_length > 0) {
    // recursively reduce allowed post length. TODO: split into multiple comments instead
    return generateComment(results, max_post_length - 800);
  } else {
    return comment;
  }
}
