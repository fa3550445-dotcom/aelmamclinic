-- Touch updated_at trigger function (idempotent)
create or replace function public.tg_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end
$$;
-- Attach trigger to all data tables (idempotent)
do $$
declare
  t text;
  tbls text[] := array[
    'patients','returns','consumptions','drugs','prescriptions','prescription_items','complaints',
    'appointments','doctors','consumption_types','medical_services','service_doctor_share',
    'employees','employees_loans','employees_salaries','employees_discounts',
    'items','item_types','purchases','alert_settings','financial_logs','patient_services'
  ];
begin
  foreach t in array tbls loop
    execute format('drop trigger if exists trg_touch_updated_at on public.%I;', t);
    execute format('create trigger trg_touch_updated_at before update on public.%I
                    for each row execute function public.tg_touch_updated_at();', t);
  end loop;
end $$;
