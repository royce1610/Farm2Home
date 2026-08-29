# Farm2Home — Setup & Deployment Guide

You now have three files:
- `schema.sql` — the database structure
- `index.html` — the full site (frontend + logic)
- this guide

## 1. Create your Supabase project

1. Go to [supabase.com](https://supabase.com) and sign up (free).
2. Click **New project**. Pick a name (e.g. `farm2home`), a database password (save it somewhere), and a region close to your users.
3. Wait ~2 minutes for it to provision.

## 2. Run the schema

1. In your Supabase project, open **SQL Editor** (left sidebar).
2. Click **New query**.
3. Paste the entire contents of `schema.sql` and click **Run**.
4. You should see "Success. No rows returned." This creates the `profiles`, `products`, `orders`, and `order_items` tables with security rules already in place.

## 3. Get your API keys

1. In the sidebar, go to **Project Settings → API**.
2. Copy the **Project URL** and the **anon public** key.

## 4. Wire the frontend

Open `index.html` and find this near the top of the `<script>` section:

```js
const SUPABASE_URL = "YOUR_SUPABASE_PROJECT_URL";
const SUPABASE_ANON_KEY = "YOUR_SUPABASE_ANON_KEY";
```

Replace both with the values you copied. Save the file.

## 5. Turn off email confirmation (for testing)

By default Supabase requires users to click a confirmation email before they can log in. For quick testing:

1. Go to **Authentication → Providers → Email**.
2. Turn off **Confirm email**.
3. Save.

(Turn this back on before a real public launch, along with setting up a custom SMTP sender.)

## 6. Test it locally

Just open `index.html` in your browser. Try:
- Sign up as a farmer → add a couple of products
- Log out, sign up as a customer → browse the marketplace, add items to your basket, place an order
- Log back in as the farmer → see the order and updated stock on the dashboard

## 7. Deploy it live

Any static host works since it's a single HTML file:

- **Netlify** — drag and drop `index.html` onto [app.netlify.com/drop](https://app.netlify.com/drop)
- **Vercel** — `vercel deploy` from the folder, or drag-and-drop via their dashboard
- **GitHub Pages** — push this file to a repo, enable Pages in repo settings

No build step, no server to manage — Supabase handles the database and auth.

## What's real now (vs. the old local-storage version)

- Passwords are hashed and managed by Supabase Auth — not stored in plain text
- Data lives in a real Postgres database, not the browser — it persists across devices and won't disappear if someone clears their cache
- Row Level Security policies enforce that farmers can only edit their own products, and customers can only see their own orders
- Stock is deducted automatically and safely via a database trigger, so two customers can't oversell the same stock

## Sensible next steps, when you're ready

- **Product photos** — Supabase Storage (a few lines of code) lets farmers upload real images instead of the text placeholder tiles
- **Payments** — Razorpay or Stripe integration for real checkout
- **Order status updates** — let farmers mark orders as confirmed/fulfilled from their dashboard
- **Search/geolocation** — show customers produce from farms near them

Happy to build any of these next — just say which one.
