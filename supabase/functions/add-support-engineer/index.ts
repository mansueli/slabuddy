import { WebClient } from "https://deno.land/x/slack_web_api@6.7.2/mod.js";
import {SupabaseClient} from "https://esm.sh/@supabase/supabase-js@2";

console.log("Function add Support Engineer is up and running!")

const slack_token = Deno.env.get("SLACK_TOKEN") ?? "";
const client = new WebClient(slack_token);
const slack_bot_token = Deno.env.get("SLACK_BOT_TOKEN") ?? "";
const bot_client = new WebClient(slack_bot_token);
const supabaseURL = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const supabase = new SupabaseClient(supabaseURL, serviceRole);

Deno.serve(async (req) => {
  const url = new URL(req.url);
  // Extract the last part of the path as the command
  const command = url.pathname.split("/").pop();
  // Log the URL and path for debugging purposes
  console.log(JSON.stringify(url.pathname, null, 2));
  const payload = await req.text();
  // If the request method is POST and the command is 'modals', handle the modal submission
  if (req.method === "POST" && command === "modal") {
    const decodedPayload = decodeURIComponent(payload.replace("payload=", ""));
    const data = JSON.parse(decodedPayload);
    if (data.type === "view_submission"){
      const selectedUser = data.view.state.values.hmtDW['users_select-action'].selected_user;
      try {
        // Call the users.info method using the WebClient
        const result = await client.users.info({
          user: selectedUser
        });
        const userEmail = result.user.profile.email ?? result.user.profile.first_name + "@example.org";
        console.log("User email: "+JSON.stringify(result.user, null, 2));
        const {data, error} = await supabase.from('support_agents').insert(
          [{first_name: result.user.profile.first_name,
           last_name: result.user.profile.last_name,
           nickname: result.user.profile.display_name,
           email: userEmail, slack_id: `<@${result.user.id}>`}]).select();
        if (error) {
          console.log(error);
          return new Response("Internal Server Error:"+JSON.stringify(error,null, 2 ), { status: 500, headers: new Headers({ "Content-Type": "text/plain" }) });
        }
      }
      catch (error) {
        console.error(error);
        return new Response("Internal Server Error:"+JSON.stringify(error,null, 2 ), { status: 500, headers: new Headers({ "Content-Type": "text/plain" }) });
      }
      return new Response("", { status: 200, headers: new Headers({ "Content-Type": "text/plain" }) });
    }
    else {
      return new Response("ok", { status: 200, headers: new Headers({ "Content-Type": "text/plain" }) });
    }
  }
  if (req.method === "POST" && command === "add") {
    const params = {};
    const pairs = decodeURIComponent(payload).split("&");
    console.log("Pairs:" +JSON.stringify(pairs, null, 2));
    for (const pair of pairs) {
      const [key, value] = pair.split("=");
      params[key] = value;
    }
    try {
      const triggerId = params["trigger_id"];
      const channelId = params["channel_id"];
      console.log(`ChannelId: ${channelId} \n command: ${command}`);
      const modalView = await getModalView();
      await bot_client.views.open({
        trigger_id: triggerId,
        view: modalView,
      });
      // Return a valid Response object
      return new Response("", { status: 200, headers: new Headers({ "Content-Type": "text/plain" }) });
    } catch (error) {
      console.error("Error opening modal:", error);
      // Return a valid error Response object
      return new Response("Internal Server Error", { status: 200, headers: new Headers({ "Content-Type": "text/plain" }) });
    }
  }
  // Return a default Response for other cases
  return new Response("", { status: 200, headers: new Headers({ "Content-Type": "text/plain" }) });
});


async function getModalView() {
   return {
    "type": "modal",
    "title": {
      "type": "plain_text",
      "text": "SLA Buddy",
      "emoji": true
    },
    "submit": {
      "type": "plain_text",
      "text": "Submit",
      "emoji": true
    },
    "close": {
      "type": "plain_text",
      "text": "Cancel",
      "emoji": true
    },
    "blocks": [
      {
        "type": "header",
        "text": {
          "type": "plain_text",
          "text": "Add a new Support Engineer to SLA Buddy",
          "emoji": true
        }
      },
      {
        "type": "divider"
      },
      {
        "type": "section",
        "text": {
          "type": "mrkdwn",
          "text": "Pick the user to include:"
        },
        "accessory": {
          "type": "users_select",
          "placeholder": {
            "type": "plain_text",
            "text": "Select a user",
            "emoji": true
          },
          "action_id": "users_select-action"
        }
      }
    ],
    "private_metadata": "add-engineer#"
  };
}

