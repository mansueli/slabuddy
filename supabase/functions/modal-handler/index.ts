import { WebClient } from "https://deno.land/x/slack_web_api@6.7.2/mod.js";
import {SupabaseClient} from "https://esm.sh/@supabase/supabase-js@2";

console.log("Function modal handler is up and running!")

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
    console.log("Decoded Payload: "+decodedPayload);
    const data = JSON.parse(decodedPayload);
    if (data.type === "view_submission"){
      const valueKeys = Object.keys(data.view.state.values);
      const dynamicKey = valueKeys[0];
      const privateCommand = data.view.private_metadata.split("#")[0];
      const privateChannelId = data.view.private_metadata.split("#")[1];
      if(privateCommand === "add-engineer"){
            const selectedUser = data.view.state.values[dynamicKey]['users_select-action'].selected_user;
            try {
              // Call the users.info method using the WebClient
              const result = await bot_client.users.info({
                user: selectedUser
              });
              console.log("User email: "+JSON.stringify(result.user, null, 2));
              const {data: supportData, error: supportError} = await supabase.from('support_agents').insert(
                [{first_name: result.user.profile.first_name,
                last_name: result.user.profile.last_name,
                nickname: result.user.profile.display_name,
                slack_id: `<@${result.user.id}>` }]).select();
              if (supportError) {
                console.log(supportError);
                return new Response("Internal Server Error:"+JSON.stringify(supportError,null, 2 ), { status: 500, headers: new Headers({ "Content-Type": "text/plain" }) });
              }
            }
            catch (error) {
              console.error(error);
              return new Response("Internal Server Error:"+JSON.stringify(error,null, 2 ), { status: 500, headers: new Headers({ "Content-Type": "text/plain" }) });
            }
            return new Response("", { status: 200, headers: new Headers({ "Content-Type": "text/plain" }) });
          }
      if (privateCommand === "sla-setup"){
        const channelInfo = await bot_client.conversations.info({
          channel: privateChannelId,
        });
        const channelName = channelInfo.channel.name;
        const escalationLevel1 = data.view.state.values.escalation_level_1.escalation_time_1.value;
        const escalationLevel2 = data.view.state.values.escalation_level_2.escalation_time_2.value;
        const escalationLevel3 = data.view.state.values.escalation_level_3.escalation_time_3.value;
        const escalationLevel4 = data.view.state.values.escalation_level_4.escalation_time_4.value;
        let escalationMessage1 = data.view.state.values.escalation_message_1.escalation_message_value_1.value;
        let escalationMessage2 = data.view.state.values.escalation_message_2.escalation_message_value_2.value;
        let escalationMessage3 = data.view.state.values.escalation_message_3.escalation_message_value_3.value;
        let escalationMessage4 = data.view.state.values.escalation_message_4.escalation_message_value_4.value;
        // Search for matches in the support_agents table and replace @name with their slack ids
        const {data:supportData, error:supportError} = await supabase.from('support_agents').select();
        if (supportError) {
          console.log(supportError);
          return new Response("Internal Server Error:"+JSON.stringify(supportError,null, 2 ), { status: 500, headers: new Headers({ "Content-Type": "text/plain" }) });
        }
        // Needs to find @names and replace them with slack ids
        for (const support of supportData) {
          let name = support.nickname;
          if (!name) {
            name = support.first_name;
          }
          const slackId = support.slack_id;
          escalationMessage1 = replaceSlackMentions(escalationMessage1, name, slackId);
          escalationMessage2 = replaceSlackMentions(escalationMessage2, name, slackId);
          escalationMessage3 = replaceSlackMentions(escalationMessage3, name, slackId);
          escalationMessage4 = replaceSlackMentions(escalationMessage4, name, slackId);
        }
        const {data:channelData, error:channelError} = await supabase.from('slack_channels').upsert(
          [ {channel: channelName , channel_id: privateChannelId,  private: 0, is_alert_channel: true,
          escalation_time: [escalationLevel1, escalationLevel2, escalationLevel3, escalationLevel4]}]).select();
        const {data:priorityData, error:priorityError} = await supabase.from('priority').upsert(
          [ {level: "1", channel_id: privateChannelId,  message: escalationMessage1},
            {level: "2", channel_id: privateChannelId,  message: escalationMessage2},
            {level: "3", channel_id: privateChannelId,  message: escalationMessage3},
            {level: "4", channel_id: privateChannelId,  message: escalationMessage4}],{onConflict:"level,channel_id"}).select();
        if (priorityError) {
          console.log(priorityError);
          return new Response("Internal Server Error:"+JSON.stringify(priorityError,null, 2 ), { status: 500, headers: new Headers({ "Content-Type": "text/plain" }) });
        }
        return new Response("", { status: 200, headers: new Headers({ "Content-Type": "text/plain" }) });
      }
    else {
      return new Response("ok", { status: 200, headers: new Headers({ "Content-Type": "text/plain" }) });
    }
  }
  }
  if (req.method === "POST" && (command === "add-engineer" || command === "sla-setup")) {
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
      const modalView =  await getModalView(command, channelId);
      console.log("ModalView: "+JSON.stringify(modalView, null, 2));
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

// Function to replace @here, @channel, and @name with their respective Slack IDs
function replaceSlackMentions(message:string, name:string, slackId:string) {
  console.log("Message: " + message + " Name: " + name + " SlackId: " + slackId);
  // Regular expression to match @here, @channel, and @name not within <>
  const regex = new RegExp(`(?<!<@)@(${name}|here|channel)(?!\\w)|(?<!<)@${name}(?!>)`, 'gi');
  // Replace @here, @channel, and @name with slack id
  const replacedMessage = message.replace(regex, (match) => {
    if (match.toLowerCase() === '@here') return '<!here>';
    if (match.toLowerCase() === '@channel') return '<!channel>';
    return `${slackId}`;
  });
  // Replace '+' signs with spaces only within the Slack ID
  return replacedMessage.replace(/\+/g, ' ');
}


async function getModalView(command: string, channelId: string) {
  switch (command) {
    case "add-engineer":
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
        "block_id": "usersPicker",
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
    "private_metadata": "add-engineer#"+channelId
  };
  case "sla-setup": {
    const [messages, times]: [string[], string[]] = await getSLASetupData(channelId);
      return {
        "type": "modal",
        "title": {
          "type": "plain_text",
          "text": "SLA Buddy - Setup",
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
            "type": "section",
            "text": {
              "type": "mrkdwn",
              "text": "Set the SLA escalation levels and messages to be sent by the bot."
            }
          },
          {
            "type": "input",
            "block_id": "escalation_level_1",
            "label": {
              "type": "plain_text",
              "text": "Escalation Level  1"
            },
            "element": {
              "type": "number_input",
              "is_decimal_allowed": false,
              "action_id": "escalation_time_1",
              "initial_value": times[0],
              "placeholder": {
                "type": "plain_text",
                "text": "Enter escalation time in minutes"
              }
            }
          },
          {
            "type": "input",
            "block_id": "escalation_message_1",
            "label": {
              "type": "plain_text",
              "text": "Message for Escalation Level  1"
            },
            "element": {
              "type": "plain_text_input",
              "action_id": "escalation_message_value_1",
              "initial_value": messages[0],
              "placeholder": {
                "type": "plain_text",
                "text": "Enter the message to be sent"
              }
            }
          },
          {
            "type": "input",
            "block_id": "escalation_level_2",
            "label": {
              "type": "plain_text",
              "text": "Escalation Level  2"
            },
            "element": {
              "type": "number_input",
              "is_decimal_allowed": false,
              "action_id": "escalation_time_2",
              "initial_value": times[1],
              "placeholder": {
                "type": "plain_text",
                "text": "Enter escalation time in minutes"
              }
            }
          },
          {
            "type": "input",
            "block_id": "escalation_message_2",
            "label": {
              "type": "plain_text",
              "text": "Message for Escalation Level  2"
            },
            "element": {
              "type": "plain_text_input",
              "action_id": "escalation_message_value_2",
              "initial_value": messages[1],
              "placeholder": {
                "type": "plain_text",
                "text": "Enter the message to be sent"
              }
            }
          },
          {
            "type": "input",
            "block_id": "escalation_level_3",
            "label": {
              "type": "plain_text",
              "text": "Escalation Level  3"
            },
            "element": {
              "type": "number_input",
              "is_decimal_allowed": false,
              "action_id": "escalation_time_3",
              "initial_value":  times[2],
              "placeholder": {
                "type": "plain_text",
                "text": "Enter escalation time in minutes"
              }
            }
          },
          {
            "type": "input",
            "block_id": "escalation_message_3",
            "label": {
              "type": "plain_text",
              "text": "Message for Escalation Level  3"
            },
            "element": {
              "type": "plain_text_input",
              "action_id": "escalation_message_value_3",
              "initial_value": messages[2],
              "placeholder": {
                "type": "plain_text",
                "text": "Enter the message to be sent"
              }
            }
          },
          {
            "type": "input",
            "block_id": "escalation_level_4",
            "label": {
              "type": "plain_text",
              "text": "Escalation Level  4"
            },
            "element": {
              "type": "number_input",
              "is_decimal_allowed": false,
              "action_id": "escalation_time_4",
              "initial_value": times[3],
              "placeholder": {
                "type": "plain_text",
                "text": "Enter escalation time in minutes"
              }
            }
          },
          {
            "type": "input",
            "block_id": "escalation_message_4",
            "label": {
              "type": "plain_text",
              "text": "Message for Escalation Level  4"
            },
            "element": {
              "type": "plain_text_input",
              "action_id": "escalation_message_value_4",
              "initial_value": messages[3],
              "placeholder": {
                "type": "plain_text",
                "text": "Enter the message to be sent"
              }
            }
          }
        ],
        "private_metadata": "sla-setup#"+channelId
      };
  }
  default:
   //return empty modal with error message
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
          "type": "section",
          "text": {
            "type": "mrkdwn",
            "text": "An error occurred while trying to open the modal. Please try again."
          }
        }
      ]
    };
  }
}

// Get SLA setup data & messages to populate the modal
async function getSLASetupData(channelId: string): Promise<[string[], string[]]>{
  const {data:slaData, error:slaError} = await supabase.from('slack_channels').select().eq('channel_id', channelId);
  if (slaError) {
    console.log(slaError);
    //return default values
    return [["escalation message 1", "escalation message 2", "escalation message 3", "escalation message 4"], ["10", "20", "35", "50"]];
  }
    const {data:priorityData, error:priorityError} = await supabase.from('priority').select().eq('channel_id', channelId);
    if (priorityError) {
      console.log(priorityError);
      //return default values
      return [["escalation message 1", "escalation message 2", "escalation message 3", "escalation message 4"], ["10", "20", "35", "50"]];
    }
    try{
    const escalationLevel1 = String(slaData[0].escalation_time[0]) ?? "10";
    const escalationLevel2 = String(slaData[0].escalation_time[1]) ?? "20";
    const escalationLevel3 = String(slaData[0].escalation_time[2]) ?? "35";
    const escalationLevel4 = String(slaData[0].escalation_time[3]) ?? "50";
    const escalationMessage1 = priorityData[0].message ?? "escalation message 1";
    const escalationMessage2 = priorityData[1].message ?? "escalation message 2";
    const escalationMessage3 = priorityData[2].message ?? "escalation message 3";
    const escalationMessage4 = priorityData[3].message ?? "escalation message 4";
    // print all messages
    console.log("escalationMessage1: "+escalationMessage1);
    console.log("escalationMessage2: "+escalationMessage2);
    console.log("escalationMessage3: "+escalationMessage3);
    console.log("escalationMessage4: "+escalationMessage4);

    //Return two arrays one with messages and the other with times
    //add types to be of string[]

    const messages: string[] = [escalationMessage1, escalationMessage2, escalationMessage3, escalationMessage4];
    const times: string[] = [escalationLevel1, escalationLevel2, escalationLevel3, escalationLevel4];
    //return an object with two arrays
    return [messages, times];
    } catch (error) {
      //return default values
      console.error(error);
      return [["escalation message 1", "escalation message 2", "escalation message 3", "escalation message 4"], ["10", "20", "35", "50"]];
    }
}