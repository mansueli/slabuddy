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
 
| Currently supported  | Includes Edge Function? | Has setup guide? |
| -------------------- | ----------------------- |----------------- |
| Zendesk              | Yes                     | Yes              |
| Freshdesk            | Yes                     | Yes              |

> [!NOTE]  
> 1. We encourage contributions to include other Help/Support platforms.

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
 - Deploy the Supabase Edge Functions (Pick the one for your help platform or edit if your platform isn't supported yet)

   
### Integrate Help Platform with Slack

It will depend on the integrations available but we recommend setting each slack channel for each level of Priority you have example: (Enterprise, Teams, Pro, Free). 
This allows you to set different SLA enforcements on each of them.


### Deploy Bot to Slack:

*Use this manifest to create the bot:* 

```manifest.yml
{
    "display_information": {
        "name": "SLA Buddy",
        "description": "Your helpful fren",
        "background_color": "#4061c7"
    },
    "features": {
        "bot_user": {
            "display_name": "SLA Buddy",
            "always_online": false
        },
        "slash_commands": [
            {
                "command": "/add-support-engineer",
                "url": "https://sb.contoso.com/functions/v1/add-support-engineer/add",
                "description": "adds an new support engineer to Horsey",
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
                "commands",
                "files:write",
                "chat:write.public"
            ]
        }
    },
    "settings": {
        "event_subscriptions": {
            "request_url": "https://sb.contoso.com/functions/v1/horsey_mentions",
            "bot_events": [
                "app_mention"
            ]
        },
        "interactivity": {
            "is_enabled": true,
            "request_url": "https://sb.contoso.com/functions/v1/add-support-engineer/modal"
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



## Configuration

- Add Support engineers to the Bot using the `slash` command `/add-support-engineer`
- Add @SLA Buddy to the channels that receive ticket information
- Set the escalation levels & messages with `/sla-setup`

## License
This code is licensed under [Apache License 2.0](https://github.com/mansueli/slabuddy/blob/main/LICENSE).
