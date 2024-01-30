import { WebClient } from "https://deno.land/x/slack_web_api@6.7.2/mod.js";
import { GiphyFetch } from 'https://esm.sh/@giphy/js-fetch-api@5';

const giphy_api = Deno.env.get("GIPHY_API") ?? "";
const slack_bot_token = Deno.env.get("SLACK_BOT_TOKEN") ?? "";
const bot_client = new WebClient(slack_bot_token);
const gf = new GiphyFetch(giphy_api);

console.log(`Slack mention reply function is up and running!`);
const positive_messages = [
  'You\'re doing great!',
  'Keep up the good work!',
  'You\'ve got this!',
  'Keep pushing!',
  'You rock!',
  'You\'re a superstar!',
  'You\'re amazing!',
];
const tags = [
  'you got this',
  'thank you',
  'you rock',
];
Deno.serve(async (req) => {
  try {
    const req_body = await req.json();
    console.log(JSON.stringify(req_body, null, 2));
    const { channel, ts } = req_body;
    await post(channel, ts );
    return new Response('ok', { status: 200 });

  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { 'Content-Type': 'application/json' },
      status: 400,
    });
  }
});

async function post(channel: string, thread_ts: string): Promise<void> {
  try {
    const msg = await get_message();
    const { text, gif, tag } = msg;
    const result = await bot_client.chat.postMessage({
      channel: channel,
      thread_ts: thread_ts,
      text: text,
      attachments: [
        {
          "image_url": gif,
          "fallback": `Gratitude GIF ${tag}`,
        }
      ]
    });
    console.info(result);
  } catch (e) {
    console.error(`Error posting message: ${e}`);
  }
}

async function get_message(): Promise<{ text: string, gif: string, tag: string }> {
  const message = positive_messages[Math.floor(Math.random() * positive_messages.length)];
  const tag = tags[Math.floor(Math.random() * tags.length)];
  const { data } = await gf.random({ tag: tag });
  console.log(data);
  const gif = data.images.downsized_medium.url;
  return { text: message, gif: gif, tag: tag };
}

