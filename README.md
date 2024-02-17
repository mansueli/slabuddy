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
![slabuddy drawio](https://github.com/mansueli/slabuddy/assets/5036432/adf2c343-e978-46cb-9d9b-d4ea0bbff54d)

- It monitors for new tickets in a few slack channels. For example, you could set different priorities depending on the Tier/Plan of your customer.
- If there is no message after an `X` amount of time, then it will post on the channels to alert people working in support.

- You can respond in the thread with a `@mention` to the bot, so they will know you acknowledged the ticket and will delay future comms in 30 min. 

## Installing

## Configuration

## License

This code is licensed under [Apache License 2.0](https://github.com/mansueli/slabuddy/blob/main/LICENSE). 
