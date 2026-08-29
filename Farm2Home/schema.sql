-- ============================================================
-- Farm2Home — Supabase schema
-- Run this in: Supabase Dashboard → SQL Editor → New query → Run
-- ============================================================

-- Extension for UUID generation
create extension if not exists "pgcrypto";

-- ------------------------------------------------------------
-- PROFILES
-- One row per authenticated user (auth.users), with a role.
-- We use Supabase Auth for login/password, and store the
-- extra farmer/customer fields here.
-- ------------------------------------------------------------
create type user_role as enum ('farmer', 'customer');

create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role user_role not null,
  name text not null,
  mobile text not null,
  email text not null,
  -- farmer-only fields
  farm_name text,
  farm_location text,
  -- customer-only field
  address text,
  created_at timestamptz not null default now()
);

alter table profiles enable row level security;

create policy "Profiles are viewable by everyone"
  on profiles for select
  using (true);

create policy "Users can insert their own profile"
  on profiles for insert
  with check (auth.uid() = id);

create policy "Users can update their own profile"
  on profiles for update
  using (auth.uid() = id);

-- ------------------------------------------------------------
-- PRODUCTS
-- Listed by farmers, visible to everyone.
-- ------------------------------------------------------------
create table products (
  id uuid primary key default gen_random_uuid(),
  farmer_id uuid not null references profiles(id) on delete cascade,
  name text not null,
  category text not null,
  price numeric(10,2) not null check (price >= 0),
  unit text not null,               -- e.g. "kg", "dozen", "litre"
  stock numeric(10,2) not null check (stock >= 0),
  description text,
  created_at timestamptz not null default now()
);

alter table products enable row level security;

create policy "Products are viewable by everyone"
  on products for select
  using (true);

create policy "Farmers can insert their own products"
  on products for insert
  with check (
    auth.uid() = farmer_id
    and exists (select 1 from profiles where id = auth.uid() and role = 'farmer')
  );

create policy "Farmers can update their own products"
  on products for update
  using (auth.uid() = farmer_id);

create policy "Farmers can delete their own products"
  on products for delete
  using (auth.uid() = farmer_id);

-- ------------------------------------------------------------
-- ORDERS + ORDER ITEMS
-- A customer places one order that can contain items from
-- multiple farmers; each item references its product/farmer.
-- ------------------------------------------------------------
create type order_status as enum ('placed', 'confirmed', 'fulfilled', 'cancelled');

create table orders (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references profiles(id) on delete cascade,
  status order_status not null default 'placed',
  total numeric(10,2) not null,
  created_at timestamptz not null default now()
);

alter table orders enable row level security;

create policy "Customers can view their own orders"
  on orders for select
  using (auth.uid() = customer_id);

create policy "Farmers can view orders containing their products"
  on orders for select
  using (
    exists (
      select 1 from order_items
      where order_items.order_id = orders.id
      and order_items.farmer_id = auth.uid()
    )
  );

create policy "Customers can create their own orders"
  on orders for insert
  with check (auth.uid() = customer_id);

create table order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  product_id uuid not null references products(id),
  farmer_id uuid not null references profiles(id),
  product_name text not null,       -- snapshot at time of order
  price numeric(10,2) not null,     -- snapshot at time of order
  quantity numeric(10,2) not null check (quantity > 0),
  subtotal numeric(10,2) not null
);

alter table order_items enable row level security;

create policy "Order items viewable by the order's customer"
  on order_items for select
  using (
    exists (
      select 1 from orders
      where orders.id = order_items.order_id
      and orders.customer_id = auth.uid()
    )
  );

create policy "Order items viewable by the item's farmer"
  on order_items for select
  using (auth.uid() = farmer_id);

create policy "Customers can insert order items for their own orders"
  on order_items for insert
  with check (
    exists (
      select 1 from orders
      where orders.id = order_items.order_id
      and orders.customer_id = auth.uid()
    )
  );

-- ------------------------------------------------------------
-- STOCK DEDUCTION
-- Automatically reduce product stock when an order item is
-- inserted, so farmers never oversell.
-- ------------------------------------------------------------
create or replace function deduct_stock()
returns trigger as $$
begin
  update products
  set stock = stock - new.quantity
  where id = new.product_id;

  if (select stock from products where id = new.product_id) < 0 then
    raise exception 'Not enough stock for product %', new.product_id;
  end if;

  return new;
end;
$$ language plpgsql security definer;

create trigger trg_deduct_stock
  after insert on order_items
  for each row execute function deduct_stock();

-- ------------------------------------------------------------
-- Helpful indexes
-- ------------------------------------------------------------
create index idx_products_farmer on products(farmer_id);
create index idx_products_category on products(category);
create index idx_orders_customer on orders(customer_id);
create index idx_order_items_order on order_items(order_id);
create index idx_order_items_farmer on order_items(farmer_id);
