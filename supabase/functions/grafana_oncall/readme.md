# Grafana OnCall integration example

You can use this Edge Function to integrate the `post_ticket_escalation` function by adding a call to it from one of the escalation levels.

You can find below an example for making the grafana_oncall after the second level of escalation within SLA Buddy. You can also note that we added an extra logic to only trigger oncall for ENTERPRISE tickets.

```ts
      if(payload.escalation_level==2)
        {
          // If enterprise posts to grafana oncall
          if (payload.channel_id == 'CXXXXXXXXXX') {
            const priority_level_array = ['high', 'urgent'];
            if (!priority_level_array.includes(payload.ticket_priority.toLowerCase())) {
              break;
            }
            const slackUrl = SLACK_ORG_LINK + payload.channel_id + '/p' + payload.thread_ts.replace('.', '');
            const supportPlatformBaseURL = 'https://slabuddy.freshdesk.com/tickets/';
            const body = {
              title: 'High Severity Enterprise Ticket',
              state: 'alerting',
              link_to_upstream_details: supportPlatformBaseURL + payload.ticket_id,
              message: 'Escalation to grafana oncall for high severity enterprise ticket.\nSlack URL: ' + slackUrl,
            };
            const headers = {
              'Content-Type': 'application/json',
             };
            const response = await fetch("https://supabase.slabuddy.com/functions/v1/grafana-oncall", {
              method: 'POST',
              headers: headers,
              body: JSON.stringify(body),
            });
            if (!response.ok) {
              throw new Error(`HTTP error! status: ${response.status}`);
            }
          }
          break;
        }
```