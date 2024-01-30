import { WebClient } from "https://deno.land/x/slack_web_api@6.7.2/mod.js";
import { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

const slack_bot_token = Deno.env.get("SLACK_BOT_TOKEN") ?? "";
const supabase_url = Deno.env.get("SUPABASE_URL") ?? "";
const service_role = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const supabase = new SupabaseClient(supabase_url, service_role);

console.log(`Slack mentions function is up and running!`);

Deno.serve(async (req) => {
  try {
    const req_body = await req.json();
    console.log(JSON.stringify(req_body, null, 2));
    const { token, challenge, type, event } = req_body;
    if (type == 'url_verification') {
      return new Response(JSON.stringify({ challenge }), {
        headers: { 'Content-Type': 'application/json' },
        status: 200,
      });
    } else if (event.type == 'app_mention') {
      // This is an app mention event
      const { user, text, channel, ts, thread_ts } = event;
      // Add your logic to handle the app mention here
      console.log(`Received app mention in channel ${channel} from user ${user}: "${text}"\n Event: ${JSON.stringify(event, null, 2)}`);
      const { error } = await supabase.rpc('increase_due_time', { 'channel': channel, 'thread_ts': thread_ts, 'ts': ts});
      if (error) {
        console.error(error);
        return new Response(JSON.stringify({ error: error.message }), {
          headers: { 'Content-Type': 'application/json' },
          status: 400,
        });
      }
      return new Response('ok', { status: 200 });
    }
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { 'Content-Type': 'application/json' },
      status: 400,
    });
  }
});
