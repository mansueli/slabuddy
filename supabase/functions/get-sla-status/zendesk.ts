// Define the Edge Function
const zendeskSubdomain = Deno.env.get("ZENDESK_SUBDOMAIN") ?? "";
const zendeskApiToken = Deno.env.get("ZENDESK_API_TOKEN") ?? "";
const zendeskEmail = Deno.env.get("ZENDESK_EMAIL") ?? "";

Deno.serve(async (req: Request) => {
    // Parse the input JSON array
    const tickets = await req.json();
    // Initialize an array to store the results
    const results = [];
    // Iterate over each ticket
    for (const ticket of tickets) {
       // Construct the Zendesk API URL for ticket metrics
       const url = `https://${zendeskSubdomain}.zendesk.com/api/v2/ticket_metrics/${ticket.ticket_id}`;
       // Prepare the Basic Authentication header
       const authHeader = `Basic ${btoa(zendeskEmail + ":" + zendeskApiToken)}`;
       // Make a GET request to the Zendesk API
       const response = await fetch(url, {
         method: 'GET',
         headers: {
           'Content-Type': 'application/json',
           'Authorization': authHeader,
         },
       });
       // Parse the response JSON
       const data = await response.json();
       console.log("data->"+JSON.stringify(data, null, 2));
       // Check if the ticket has been replied to by looking at the 'replies' field
       const wasReplied = data.ticket_metric.replies > 0;
       const createdAt = new Date(data.ticket_metric.created_at);
       const replyTimeInMinutes = data.ticket_metric.reply_time_in_minutes.calendar;
       const firstReplyTimestamp = new Date(createdAt.getTime() + replyTimeInMinutes * 60000);
       // Add the result to the results array
       results.push({
         ticket_id: ticket.ticket_id,
         was_replied: wasReplied,
         timestamp: firstReplyTimestamp.toISOString(),
       });
    }
    // Return the results as JSON
    return new Response(JSON.stringify(results), {
       headers: {
         'Content-Type': 'application/json',
       },
    });
});
