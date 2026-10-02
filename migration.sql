-- Farm2Home update 003: remove products from sale without losing order history.
-- Apply after migration.sql and migration_002_payments_cancellation.sql.
-- Safe to run again; no products or orders are deleted.
begin;
alter table public.products add column if not exists is_archived boolean not null default false;
create or replace function public.checkout(items jsonb,delivery text,method text default 'cod',reference text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare oid uuid; entry record; p products%rowtype; settings farmer_payment_settings%rowtype; amount numeric:=0;
begin
 if auth.uid() is null or not exists(select 1 from profiles where id=auth.uid() and role='customer') then raise exception 'Customer login required';end if;
 if delivery is null or length(trim(delivery))<5 or length(delivery)>1000 then raise exception 'Provide a valid delivery address';end if;
 if method is null or method not in ('cod','upi') then raise exception 'Invalid payment method';end if;
 if method='upi' and nullif(trim(reference),'') is not null then raise exception 'Refresh the website. Place the order first, then pay each farmer in My orders';end if;
 if items is null or jsonb_typeof(items)<>'array' then raise exception 'Invalid basket';end if;
 if jsonb_array_length(items)=0 or jsonb_array_length(items)>100 then raise exception 'Invalid basket';end if;
 if exists(select 1 from jsonb_to_recordset(items) as x(product_id uuid,quantity numeric) where product_id is null or quantity is null or quantity<=0 or quantity::text in ('NaN','Infinity','-Infinity') or quantity<>round(quantity,2)) then raise exception 'Use positive quantities with at most two decimal places';end if;
 insert into orders(customer_id,total,delivery_address,payment_method,payment_status)
 values(auth.uid(),0,trim(delivery),method,'pending') returning id into oid;
 for entry in select product_id,sum(quantity) quantity from jsonb_to_recordset(items) as x(product_id uuid,quantity numeric) group by product_id order by product_id loop
  select * into p from products where id=entry.product_id for update;
  if not found or p.is_archived then raise exception 'A product in your basket has been removed from sale. Remove it from your basket and try again';end if;
  if p.stock<entry.quantity then raise exception 'Insufficient stock for %',p.name;end if;
  update products set stock=stock-entry.quantity where id=p.id;
  insert into order_items(order_id,product_id,farmer_id,product_name,price,quantity,subtotal)
  values(oid,p.id,p.farmer_id,p.name,p.price,entry.quantity,round(p.price*entry.quantity,2));
  amount:=amount+round(p.price*entry.quantity,2);
 end loop;
 -- Snapshot each destination, so editing a UPI ID cannot redirect an existing order.
 for entry in select i.farmer_id,sum(i.subtotal) total,coalesce(f.farm_name,f.name) farm_name
 from order_items i join profiles f on f.id=i.farmer_id where i.order_id=oid group by i.farmer_id,f.farm_name,f.name order by i.farmer_id loop
  settings:=null;
  select * into settings from farmer_payment_settings where farmer_id=entry.farmer_id for share;
  if method='upi' and (settings.farmer_id is null or not settings.enabled) then raise exception 'One or more farms have not enabled UPI. Choose cash on delivery';end if;
  insert into order_payments(order_id,farmer_id,customer_id,farm_name,amount,method,upi_id,payee_name)
  values(oid,entry.farmer_id,auth.uid(),entry.farm_name,entry.total,method,case when method='upi' then settings.upi_id end,case when method='upi' then settings.payee_name end);
 end loop;
 update orders set total=amount where id=oid;
 insert into notifications(user_id,body) select distinct farmer_id,'New order received. Open your dashboard to confirm fulfilment.' from order_items where order_id=oid;
 insert into notifications(user_id,body) values(auth.uid(),case when method='upi' then 'Order placed. Open My orders to pay each farmer directly.' else 'Order placed. Pay each farmer on delivery.' end);
 return oid;
end $$;
revoke all on function public.checkout(jsonb,text,text,text) from public;
grant execute on function public.checkout(jsonb,text,text,text) to authenticated;


notify pgrst, 'reload schema';
commit;
