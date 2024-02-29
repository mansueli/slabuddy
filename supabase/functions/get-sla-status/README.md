# Example Functions to get Reply Status from the Help Platforms

You should rename the function to index.ts (from `zendesk.ts` or `freshdesk.ts`) before deploying it. You will also need to set secrets depending on the platform that you are using. You can also use this as a starting point to add support for more help platforms.


## Freshdesk secrets:
Setting the Freshdesk secrets to be available on Supabase Edge Functions:

Secrets needed:

 - FRESHDESK_DOMAIN
 - FRESHDESK_API

Example:
```bash
# Set the Zendesk email
supabase secrets set --project-ref <ref> FRESHDESK_DOMAIN=your_subdomain

# Set the Freshdesk API key:
supabase secrets set --project-ref <ref> FRESHDESK_API=your_api_key
```


## Zendesk secrets:

Setting the Zendesk secrets to be available on Supabase Edge Functions:

Secrets needed:
 - ZENDESK_EMAIL
 - ZENDESK_SUBDOMAIN
 - ZENDESK_API_TOKEN

Example:
```bash
# Set the Zendesk email
supabase secrets set --project-ref <ref> ZENDESK_EMAIL=your_zendesk_email@example.com

# Set the Zendesk subdomain
supabase secrets set --project-ref <ref> ZENDESK_SUBDOMAIN=your_zendesk_subdomain

# Set the Zendesk API token
supabase secrets set --project-ref <ref> ZENDESK_API_TOKEN=your_zendesk_api_token
```