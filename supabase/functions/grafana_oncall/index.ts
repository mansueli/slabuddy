// Follow this setup guide to integrate the Deno language server with your editor:
// https://deno.land/manual/getting_started/setup_your_environment
// This enables autocomplete, go to definition, etc.

console.log("Grafana function started")

// Define the Grafana endpoint and headers
const grafanaWebhookEndpoint = Deno.env.get('GRAFANA_WEBHOOK_URL') ?? '';
const headers = {
 'Content-Type': 'application/json',
};

// The main function that will be called by Supabase
Deno.serve(async (req) => {
 try {
    // Parse the request body as JSON
    const reqBody = await req.json();
    console.log(JSON.stringify(reqBody, null, 2));

    // Prepare the data to be sent to Grafana
    const data = {
      title: reqBody.title,
      state: reqBody.state,
      link_to_upstream_details: reqBody.link_to_upstream_details,
      message: reqBody.message
    };
    // Make the POST request to Grafana
    const response = await fetch(grafanaWebhookEndpoint, {
      method: 'POST',
      headers: headers,
      body: JSON.stringify(data),
    });

    if (!response.ok) {
      throw new Error(`HTTP error! status: ${response.status}`);
    }
    // Return a success response
    return new Response('Request to Grafana successful', {
      status: 200,
    });
 } catch (error) {
    console.error('Error making request to Grafana:', error);
    // Return an error response
    return new Response(JSON.stringify({
      error: error.message
    }), {
      headers: {
        'Content-Type': 'application/json'
      },
      status: 500,
    });
 }
});
