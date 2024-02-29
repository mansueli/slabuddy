# [<img alt="SLA-buddy mascot" src="https://github.com/mansueli/slabuddy/assets/5036432/b2d06907-ca89-4f4b-86eb-798cb6dfa8bd" width="73" />]() SLA Buddy

## SLA Buddy: a helpful robot to help you meet Service Level Agreement in Slack.

This bot started as an internal tooling project to help enforce and meet SLAs at [Supabase](https://github.com/supabase/supabase). It borrows many mechanisms and most of the functionality designed in [supa_queue](https://github.com/mansueli/supa_queue) while extending them to be a standalone product.

## Pre-requisites
 - [<img alt="Supabase logo" src="https://github.com/mansueli/slabuddy/assets/5036432/d0f24eae-acd8-4701-9754-9979ce4448f9" width="12" />]() Supabase
   - pg_cron
   - pg_net
   - Vault
   - Edge Functions
 - [<img alt="SLA-buddy mascot" src="https://github.com/mansueli/slabuddy/assets/5036432/4352ffe6-e61f-43e4-90af-ef97c79eeb86" width="20" />]() Slack API

## Supported ticketing Platforms¹:

| Currently supported  | Includes Edge Function? | Has setup guide?      |
| -------------------- | ----------------------- |---------------------- |
| Zendesk              | Yes                     | [Yes](#zendesk-setup) |
| Freshdesk            | Yes                     | [Yes](#zendesk-setup) |

> [!NOTE]
> 1. We encourage contributions to include other Help/Support platforms.
> 2. Platform specific Edge Functions are in this [directory](https://github.com/mansueli/slabuddy/tree/main/supabase/functions/get-sla-status)

## How it works:

Here's the top-level diagram explaining how it works:
![slabuddy drawio](https://github.com/mansueli/slabuddy/assets/5036432/44c35c61-9120-4e82-adf4-2a984da7c87a)

- It monitors for new tickets in a few slack channels. For example, you could set different priorities depending on the Tier/Plan of your customer.
- If there is no message after an `X` amount of time, then it will post on the channels to alert people working in support.

- You can respond in the thread with a `@mention` to the bot, so they will know you acknowledged the ticket and will delay future comms in 30 min.

## Installing

### Get a Supabase Project
 - Setup a Supabase project for the bot [here](https://database.new)
 - Install the [Supabase CLI](https://supabase.com/docs/guides/cli/getting-started#installing-the-supabase-cli)
 - Login to your Supabase instance in the CLI
 - Run the [initial.sql](https://raw.githubusercontent.com/mansueli/slabuddy/main/supabase/migrations/initial.sql) in the database.
 - Deploy the Supabase Edge Functions with the option `--no-verify-jwt`


### Integrate Help Platform with Slack

It will depend on the integrations available but we recommend setting each slack channel for each level of Priority you have example: (Enterprise, Teams, Pro, Free).
This allows you to set different SLA enforcements on each of them.


### Deploy Bot to Slack:

*Use this manifest to create the bot:*

```manifest.json
{
    "display_information": {
        "name": "Sla Buddy",
        "description": "Your helpful fren",
        "background_color": "#4061c7"
    },
    "features": {
        "bot_user": {
            "display_name": "Sla Buddy",
            "always_online": false
        },
        "slash_commands": [
            {
                "command": "/add-support-engineer",
                "url": "https://supabase.slabuddy.com/functions/v1/modal-handler/add-engineer",
                "description": "adds an new support engineer to SLA Buddy",
                "usage_hint": "Just run it without arguments and use the modal",
                "should_escape": false
            },
            {
                "command": "/sla-setup",
                "url": "https://supabase.slabuddy.com/functions/v1/modal-handler/sla-setup",
                "description": "setup or edit the configuration for a given channel",
                "usage_hint": "Just run it without arguments and use the modal",
                "should_escape": false
            }
        ]
    },
    "oauth_config": {
        "scopes": {
            "bot": [
                "app_mentions:read",
                "channels:history",
                "channels:join",
                "channels:read",
                "chat:write",
                "links:write",
                "users:read",
                "commands",
                "files:write",
                "chat:write.public"
            ]
        }
    },
    "settings": {
        "event_subscriptions": {
            "request_url": "https://supabase.slabuddy.com/functions/v1/get-mentions",
            "bot_events": [
                "app_mention"
            ]
        },
        "interactivity": {
            "is_enabled": true,
            "request_url": "https://supabase.slabuddy.com/functions/v1/modal-handler/modal"
        },
        "org_deploy_enabled": false,
        "socket_mode_enabled": false,
        "token_rotation_enabled": false
    }
}
```
> [!NOTE]
> You'll need to edit the URLs being called according to your project URL on Supabase.

## Setting the secrets in Vault & Edge Functions:

## FAQs:
<details>

<summary>Frequentely Asked Questions</summary>

### Can I use this in the Supabase Free plan?

Yes, on a busy day, you should expect up to around 7500 edge function invocations/day which would sum up to 225k invocations/month in the billing period.
The memory might be constrained. If you want to make it more reliable, a Pro Plan + small compute add-on is recommended. This would be 30$/month if you don't use supabase for anything else, but [around 15$/month](https://supabase.com/docs/guides/platform/compute-add-ons) if you already use a pro Supabase org.

### Why I cannot disable SLA Buddy?  ( it just postpones messages with `@mentions`)

We believe that even if you are unable to answer to a user, you should still be able to give them some information about the next steps. E.g I am escalating this to the responsible team and a human-provided message will enhance the trust of your users.

### What are the recommendations for setting it up?

We believe that the trickiest part of a good experience is to nail the first two escalation levels. Since these will be the most widely used, it should be the least intrusive as possible.
So, you should customize the Edge-Function `post-ticket-escalation` with more personalized tagging ensuring that it fits your team.

</details>


## Configuration

- Add Support engineers to the Bot using the `slash` command `/add-support-engineer`
- Add @SLA Buddy to the channels that receive ticket information
- Set the escalation levels & messages with `/sla-setup`

## FreshDesk setup:
<details>

<summary>Instruction guide for setting up with Freshdesk</summary>

### 1. Add the Slack Integration for FreshDesk:
https://support.freshdesk.com/support/solutions/articles/206103-the-slack-app

### 2. Create and configure channels to receive the notifications:

To push notifications to Slack when new tickets are created in Freshdesk, go to Admin > Workflows > Automations > Ticket creation tab > New rule

### 3. Format expected to parse the messages:

```
*Ticket ID*: <message here>
*Ticket priority*: <priority here>
*Type*: <extra data for the ticket>
```

### 4. Use the `/sla-setup` slash command to set SLA Buddy to monitor the channel

### 5. Setting the secrets for the Freshdesk Edge Function:

Setting the Freshdesk secrets to be available on Supabase Edge Functions:

Secrets needed:

 - FRESHDESK_DOMAIN
 - FRESHDESK_API

</details>

## Zendesk setup:
<details>

<summary>Instruction guide for setting up with Zendesk</summary>

### 1. Setup Zendesk to send Slack Notifications to Slack:
https://support.zendesk.com/hc/en-us/community/posts/4409515204506-Send-notifications-to-Slack

### 2. Create and configure channels to receive the notifications:

### 3. Format expected to parse the messages:

This is the format expected by the scanner edge function:

```
*Ticket ID*: <message here>
*Ticket priority*: <priority here>
*Type*: <extra data for the ticket>
```
You can check this [guide](https://support.zendesk.com/hc/en-us/community/posts/4409515204506-Send-notifications-to-Slack) for sending slack messages.
Example of attachment to use for the message box:

```
{
 "attachments": [
    {
      "fallback": "New problem ticket created: {{ticket.id}}",
      "pretext": "New problem ticket created: {{ticket.id}}",
      "color": "#D00000",
      "fields": [
        {
          "title": "Ticket ID",
          "value": "{{ticket.id}}",
          "short": true
        },
        {
          "title": "Ticket Priority",
          "value": "{{ticket.priority}}",
          "short": true
        },
        {
          "title": "Type",
          "value": "{{ticket.type}}",
          "short": true
        }
      ]
    }
 ]
}

You can check [Zendesk placeholders](https://support.zendesk.com/hc/en-us/articles/4408886858138-Zendesk-Support-placeholders-reference) if you want to configure more how to pass type and other data.

```

### 4. Use the `/sla-setup` slash command to set SLA Buddy to monitor the channel

### 5. Deploy the secrets for the Edge Function:

Setting the Zendesk secrets to be available on Supabase Edge Functions:

Secrets needed:
 - ZENDESK_EMAIL
 - ZENDESK_SUBDOMAIN
 - ZENDESK_API_TOKEN


</details>

## License
This code is licensed under [Apache License 2.0](https://github.com/mansueli/slabuddy/blob/main/LICENSE).
