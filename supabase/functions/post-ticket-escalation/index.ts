import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { WebClient } from "https://deno.land/x/slack_web_api@6.7.2/mod.js";

const SLACK_ORG = Deno.env.get("SLACK_ORG") ?? "";
const SLACK_ORG_LINK = `https://${SLACK_ORG}.slack.com/archives/`;
const slack_bot_token = Deno.env.get("SLACK_BOT_TOKEN") ?? "";
const bot_client = new WebClient(slack_bot_token);
const supabaseURL = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const supabase = createClient(supabaseURL, serviceRole);


interface Payload {
  thread_ts: string;
  channel_id: string;
  escalation_level: number;
  ticket_id: string;
}

interface SupportNames {
  data: string[];
  error: any;
}

Deno.serve(async (req: Request) => {
  console.log("Starting the support_events function");
  let debug_mode = false;
  try {
    const token = req.headers.get("Authorization")?.split(" ")[1];
    if (!token) {
      return new Response("Missing authorization header", { status: 401 });
    }
    if (token !== serviceRole) {
      console.log(token + "\n" + serviceRole);
      return new Response("Not authorized", { status: 403 });
    }

    // Parse the payload
    const payload: Payload = await req.json();

    // Get the current events
    const { data: currentEvents, error: currentEventsError } = await supabase.rpc<SupportNames>('get_current_events');
    if (currentEventsError) {
      console.error(currentEventsError);
      return new Response(JSON.stringify({ error: "An error occurred ->"+currentEventsError.stack+'\n\n' }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      });
    }

    // Handle the different escalation levels
    let message = '';
    const {data, error} = await supabase.from('priority').select('message').eq('id', payload.escalation_level).eq('channel_id', payload.channel_id);
    if (error) {
      console.error(error);
      return new Response(JSON.stringify({ error: "An error occurred ->"+error.stack+'\n\n' }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      });
    }
    message = data[0].message;
    // Post the message to the Slack thread
    if (!debug_mode) {
      await post(payload.channel_id, payload.thread_ts, message);
    }

    return new Response(JSON.stringify({ "status": message, "debug_mode": debug_mode }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (error) {
    console.error(error.message);
    return new Response(JSON.stringify({ error: "An error occurred ->"+error.stack+'\n\n' }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});

async function post(channel: string, thread_ts: string, message: string): Promise<void> {
  try {
    const result = await bot_client.chat.postMessage({
      channel: channel,
      thread_ts: thread_ts,
      text: message,
      link_names: true,
    });
    console.info(result);
  } catch (e) {
    console.error(`Error posting message: ${e}`);
  }
}
