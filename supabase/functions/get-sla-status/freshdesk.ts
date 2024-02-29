// Define the Edge Function

const freshdeskDomain = Deno.env.get("FRESHDESK_DOMAIN") ?? "";
const freshdeskApiKey = Deno.env.get("FRESHDESK_API") ?? "";


Deno.serve(async (req: Request) => {
    // Parse the input JSON array
    const tickets = await req.json();
    // Initialize an array to store the results
    const results = [];
    // Iterate over each ticket
    for (const ticket of tickets) {
       // Construct the Freshdesk API URL with 'include=stats' to get the ticket stats
       const url = `https://${freshdeskDomain}.freshdesk.com/api/v2/tickets/${ticket.ticket_id}?include=stats`;
       // Prepare the Basic Authentication header
       const authHeader = `Basic ${btoa(freshdeskApiKey + ":X")}`;
       // Make a GET request to the Freshdesk API
       const response = await fetch(url, {
         method: 'GET',
         headers: {
           'Content-Type': 'application/json',
           'Authorization': authHeader,
         },
       });
       // Parse the response JSON
       const data = await response.json();
       // Check if the ticket has been replied to by looking at the 'first_responded_at' time
       const wasReplied = data.stats.first_responded_at !== null;
       // Add the result to the results array
       results.push({
         ticket_id: ticket.ticket_id,
         was_replied: wasReplied,
         timestamp: data.stats.first_responded_at,
       });
    }
    // Return the results as JSON
    return new Response(JSON.stringify(results), {
       headers: {
         'Content-Type': 'application/json',
       },
    });
   });
