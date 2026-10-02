# Farm2Home upgraded project

## What changed

The Supabase-backed version of your original site is the base. The new interface uses navy, teal, orange and bright white, with responsive product cards and dashboards.

Included: separate customer/farmer signup, product images and stock management, search by product, category/location/price filters, price sorting, browser wishlist, basket quantity editing and per-account browser basket persistence, delivery address, transactional checkout, customer history, per-farm order status updates, purchase-only reviews, direct customer/farmer messaging, database-generated notifications, and category-based product suggestions. Suggestions are rule-based, not an AI service. Messages and notifications refresh when opened; chat also has a Refresh button.

## Install

1. Keep a database backup before making changes.
2. If this is a new Supabase project, run `schema.sql` first. If your original tables already exist, skip that file.
3. Run `migration.sql` once in Supabase SQL Editor. It adds features and policies without deleting your existing records. Do not rerun it unchanged: policy and trigger names will already exist. The migration replaces direct client order writes with a transactional checkout function and restricts public profile access to a directory of farm names and locations.
4. Open `index.html` and check `SUPABASE_URL` and `SUPABASE_ANON_KEY`. Your existing project URL and public publishable key are retained. Never put a service-role key into HTML.
5. Serve this folder locally, for example `python3 -m http.server 8000`, then open `http://localhost:8000`. Supabase and the font/CDN assets require an internet connection.
6. Keep email confirmation enabled for real accounts and configure Supabase Auth redirect URLs for your eventual deployed URL. After signup, confirm your email if required, then log in.

## Payment details

Cash on delivery is available by default. It records the payment method and pending status with the order. No card data is requested or stored.

Manual UPI is included but disabled until you edit this setting in `index.html`:

```js
const PAYMENT_CONFIG = {
  upiId: 'your-merchant-id@yourbank',
  payeeName: 'Your registered merchant name'
};
```

Use a real merchant identity you control. Customers see the payee, UPI ID and basket amount, can open a UPI app on supported devices, and enter their transaction reference. The order stores that reference with `awaiting_verification` status. A reference does not prove payment. Compare it with your merchant statement and the database order total. If stock/price changed or checkout fails after a transfer, contact the merchant to reconcile/refund the payment before retrying; do not pay twice.

This is a central marketplace payment destination. For baskets spanning several farms, the marketplace operator must handle settlement with farmers. There is no automatic settlement or refund service in this release.

Verified payment status must be updated by the trusted project operator in Supabase after checking the actual receipt; customer/farmer browser accounts cannot mark orders paid. For COD, confirm collection before doing the same. No automatic payment gateway, webhook verification or online card checkout is configured. Adding Razorpay/Stripe requires your merchant account and a server-side secret plus a verified webhook; secret keys must never go into this HTML file.

## Test the complete workflow

- Sign up/confirm/login as a farmer; add a product and an image.
- In a second browser session, create a customer account. Search/filter/sort, save a product, add/edit basket items and enter a delivery address.
- Place a COD order. Check order details and farmer notifications; stock should decrease.
- As the farmer, change each item from placed to confirmed, then fulfilled. The overall order advances after every participating farm reaches the stage.
- As the customer, check item progress and notifications, leave a review, and send the farmer a message from a product’s details page. Reply as the farmer.
- Configure your merchant UPI ID only when ready; use a controlled small transaction to validate receipt reconciliation.
- Test insufficient stock and two customers ordering the final unit. The entire order must roll back on insufficient stock. All totals are calculated using current database prices.

## Validation and limits

JavaScript syntax is checked. Automated DOM interaction checks with a mocked backend passed for product rendering, search, filters, sorting, wishlist, details, basket quantities, stock validation, UPI configuration checks and checkout request/reset. SQL files passed PostgreSQL syntax parsing. These checks do not prove your live Supabase configuration, storage policies, email delivery or payments work. Visual browser checks could not run because the browser download was unavailable. No live database migration or real payment is performed by delivering these files. Run the workflow above after installation.

The wishlist is saved only in the current browser. Basket persistence belongs to the signed-in account in that browser, and checkout revalidates prices and stock. The messaging inbox loads up to 200 messages and notifications load the latest 50. Product removal is blocked by the database if historical orders reference that product; set stock to zero to stop selling it. Online payment verification, automatic refunds, shipment courier integration and a production admin console are not included.

Your original files remain separate. This folder is the complete upgraded source package.
