import { WebClient } from "https://deno.land/x/slack_web_api@6.7.2/mod.js";
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";

const slack_bot_token = Deno.env.get("SLACK_BOT_TOKEN") ?? "";
const bot_client = new WebClient(slack_bot_token);
const supabase_url = Deno.env.get("SUPABASE_URL") ?? "";
const service_role = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const supabase = createClient(supabase_url, service_role);

Deno.serve(async (req) => {
  console.log("=== FUNCTION STARTED ===");
  const authorization = req.headers.get("Authorization");
  if (!authorization) throw new Error("Authorization header is missing.");
  if (!authorization.includes(service_role)) {
    throw new Error("Authorization header is invalid.");
  }
  const { channel_id } = await req.json();
  console.log("received channel_id:" + channel_id);
  if (!channel_id) throw new Error("Channel ID is missing.");
  const { data, error } = await supabase.from("slack_channels").select("*").eq(
    "channel_id",
    channel_id,
  ).limit(1);
  const channel = data[0];
  if (error) throw new Error(error.message + JSON.stringify(channel, null, 2));
  console.log("here:\n" + JSON.stringify(channel, null, 2));
  const tickets = await loop_through_channel(channel);
  console.log("=== FUNCTION ENDED ===");
  return new Response(
    "OK + " + JSON.stringify(channel, null, 2) +
      JSON.stringify(channel_id, null, 2) + JSON.stringify(tickets, null, 2),
    { headers: { "Content-Type": "text/plain" } },
  );
});

async function loop_through_channel(channel): Promise<String> {
  let conversation_history: any[] = [];
  console.log(`Scanning ${JSON.stringify(channel.channel, null, 2)}`);
  try {
    const result = await bot_client.conversations.history({
      channel: channel.channel_id,
      limit: 20,
    });

    conversation_history = result.messages;
    //console.log(`${conversation_history.length} messages found in ${channel.channel}\n\n`+JSON.stringify(conversation_history, null, 2));
  } catch (e) {
    console.log(`Error creating conversation: ${e} + ${channel.channel_id}`);
  }

  let tasks_to_insert: any[] = [];
  for (const message of conversation_history) {
    try {
      const ticket_data = extract_ticket_data_attachments(message.attachments);
      if (!ticket_data != null) {
        const msg_dic = {
          "channel_name": channel.channel,
          "channel_id": channel.channel_id,
          "message": `<@${message.user}> wrote: \n${message.text}`,
          "ts": timestamp_to_iso_string(message.ts.split(".")[0]),
          "ts_ms": message.ts.split(".")[1],
          "ticket_number": ticket_data?.ticket_id,
          "ticket_priority": ticket_data?.ticket_priority,
          "ticket_type": ticket_data?.ticket_type
        };
        const { data, error } = await supabase.from("slack_msg").insert(
          msg_dic,
        );
        if (error) {
          console.log(error);
        }
      }
    } catch (e) {
      console.log(e);
    }
  }
  // Insert all tasks in a single Supabase call
  const { data: inserted_tasks, error: task_insertion_error } = await supabase
    .from("checking_tasks_queue")
    .insert(tasks_to_insert);

  if (task_insertion_error) {
    console.log(task_insertion_error);
  } else {
    console.log("Tasks inserted successfully:", inserted_tasks);
  }
}

function extract_ticket_data_attachments(attachments):
  { ticket_id: string; ticket_priority: string; ticket_type: string } | null {
  // Iterate through the attachments array
  for (const attachment of attachments) {
    if (attachment.text) {
      // Split the text into an array of lines
      const lines = attachment.text.split('\n');
      let ticket_id, ticket_priority, ticket_type;
      for (let line of lines) {
        if (line.startsWith("*Ticket ID*: ")) {
          ticket_id = line.substring("*Ticket ID*: ".length).trim();
        } else if (line.startsWith("*Ticket priority*: ")) {
          ticket_priority = line.substring("*Ticket priority*: ".length).trim();
        } else if (line.startsWith("*Type*: ")) {
          ticket_type = line.substring("*Type*: ".length).trim();
        }
        if (ticket_id && ticket_priority && ticket_type) {
          return { ticket_id, ticket_priority, ticket_type };
        }
      }
    }
  }
  return null; // Return null if ticket ID is not found
}

function timestamp_to_iso_string(timestamp: string): string {
  const timestamp_ms = parseInt(timestamp, 10) * 1000;
  const date = new Date(timestamp_ms);
  return date.toISOString();
}
