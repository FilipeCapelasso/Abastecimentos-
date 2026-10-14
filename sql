update public.app_config set valor = '8628884766:AAGJHRoelEX2vM1tACQ2luJkDVOmFQhx1Tg' where chave = 'telegram_token';
update public.app_config set valor = '7694564020' where chave = 'telegram_chat_ids';

-- =====================================================================
-- CONTROLE DE ABASTECIMENTOS - BANCO DE DADOS (SUPABASE / POSTGRES)
-- Como usar: Supabase > SQL Editor > New query > cole TUDO > Run.
-- Pode rodar de novo sem medo (os comandos são repetíveis).
-- IMPORTANTE: este arquivo NÃO contém o token do Telegram. Veja o passo 9.
-- =====================================================================

-- 1) EXTENSÃO PARA ENVIAR MENSAGENS AO TELEGRAM (feito pelo banco, não pelo site)
create extension if not exists pg_net with schema extensions;

-- 2) USUÁRIOS E PERMISSÕES
-- papel: 'admin' (registra tudo), 'leitura' (só consulta), 'bloqueado' (sem acesso)
create table if not exists public.perfis (
  user_id   uuid primary key references auth.users(id) on delete cascade,
  nome      text,
  papel     text not null default 'bloqueado' check (papel in ('admin','leitura','bloqueado')),
  criado_em timestamptz not null default now()
);

-- O PRIMEIRO usuário criado vira admin. Os seguintes entram como 'bloqueado'
-- até você liberar (passo 8). Assim, ninguém de fora enxerga os dados.
create or replace function public.novo_usuario() returns trigger
language plpgsql security definer set search_path = public as $f$
begin
  insert into public.perfis(user_id, nome, papel)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'nome', split_part(new.email,'@',1)),
          case when exists (select 1 from public.perfis) then 'bloqueado' else 'admin' end);
  return new;
end $f$;

drop trigger if exists ao_criar_usuario on auth.users;
create trigger ao_criar_usuario after insert on auth.users
  for each row execute function public.novo_usuario();

create or replace function public.papel_atual() returns text
language sql stable security definer set search_path = public as $f$
  select papel from public.perfis where user_id = auth.uid()
$f$;
create or replace function public.eh_autorizado() returns boolean
language sql stable security definer set search_path = public as $f$
  select coalesce(public.papel_atual() in ('admin','leitura'), false)
$f$;
create or replace function public.eh_admin() returns boolean
language sql stable security definer set search_path = public as $f$
  select coalesce(public.papel_atual() = 'admin', false)
$f$;

-- 3) CONFIGURAÇÕES PRIVADAS (token do Telegram). Ninguém pelo site consegue ler.
create table if not exists public.app_config (
  chave text primary key,
  valor text not null
);
alter table public.app_config enable row level security;   -- sem políticas = fechado
insert into public.app_config(chave, valor) values
  ('telegram_token',    'COLE_AQUI_O_TOKEN'),
  ('telegram_chat_ids', 'COLE_AQUI_O_ID')
on conflict (chave) do nothing;

-- 4) TABELAS PRINCIPAIS (sem horário: só a data)
create table if not exists public.abastecimentos (
  id          uuid primary key default gen_random_uuid(),
  numero      integer generated always as identity,
  data        date not null,
  pessoa      text not null check (length(trim(pessoa)) > 0),
  veiculo     text not null check (length(trim(veiculo)) > 0),
  placa       text,
  valor       numeric(14,2) not null check (valor > 0),
  observacoes text,
  cancelado   boolean not null default false,
  criado_em   timestamptz not null default now(),
  criado_por  uuid default auth.uid()
);

create table if not exists public.pagamentos (
  id             uuid primary key default gen_random_uuid(),
  chave          uuid not null unique,          -- impede pagamento duplicado
  data           date not null,
  valor          numeric(14,2) not null check (valor > 0),
  forma          text not null check (forma in ('Pix','Dinheiro','Transferência')),
  observacao     text,
  estornado      boolean not null default false,
  estornado_em   timestamptz,
  motivo_estorno text,
  criado_em      timestamptz not null default now(),
  criado_por     uuid default auth.uid()
);

-- Como cada pagamento foi distribuído entre os abastecimentos (FIFO)
create table if not exists public.alocacoes (
  id               uuid primary key default gen_random_uuid(),
  pagamento_id     uuid not null references public.pagamentos(id)     on delete restrict,
  abastecimento_id uuid not null references public.abastecimentos(id) on delete restrict,
  valor            numeric(14,2) not null check (valor > 0),
  criado_em        timestamptz not null default now()
);
create index if not exists ix_aloc_abast on public.alocacoes(abastecimento_id);
create index if not exists ix_aloc_pag   on public.alocacoes(pagamento_id);
create index if not exists ix_abast_data on public.abastecimentos(data, criado_em);

-- Registro de tudo que foi criado/alterado (auditoria)
create table if not exists public.historico (
  id          bigint generated always as identity primary key,
  tabela      text not null,
  registro_id uuid not null,
  acao        text not null,
  antes       jsonb,
  depois      jsonb,
  usuario     uuid default auth.uid(),
  criado_em   timestamptz not null default now()
);
create index if not exists ix_hist_reg on public.historico(registro_id);

create or replace function public.auditar() returns trigger
language plpgsql security definer set search_path = public as $f$
begin
  insert into public.historico(tabela, registro_id, acao, antes, depois)
  values (tg_table_name, coalesce(new.id, old.id), tg_op,
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end);
  return coalesce(new, old);
end $f$;

drop trigger if exists aud_abast on public.abastecimentos;
create trigger aud_abast after insert or update or delete on public.abastecimentos
  for each row execute function public.auditar();
drop trigger if exists aud_pag on public.pagamentos;
create trigger aud_pag after insert or update or delete on public.pagamentos
  for each row execute function public.auditar();

-- 5) VISÃO COM OS SALDOS (pago, pendente e situação de cada abastecimento)
create or replace view public.v_abastecimentos with (security_invoker = true) as
select a.*,
       coalesce(p.pago, 0)                 as pago,
       a.valor - coalesce(p.pago, 0)       as pendente,
       case when a.cancelado                  then 'cancelado'
            when coalesce(p.pago,0) >= a.valor then 'pago'
            when coalesce(p.pago,0) > 0        then 'parcial'
            else 'pendente' end            as situacao
from public.abastecimentos a
left join lateral (
  select sum(al.valor) as pago
  from public.alocacoes al
  join public.pagamentos pg on pg.id = al.pagamento_id
  where al.abastecimento_id = a.id and not pg.estornado
) p on true;

-- 6) SEGURANÇA: o site só LÊ as tabelas; toda escrita passa pelas funções abaixo
alter table public.perfis          enable row level security;
alter table public.abastecimentos  enable row level security;
alter table public.pagamentos      enable row level security;
alter table public.alocacoes       enable row level security;
alter table public.historico       enable row level security;

drop policy if exists ler_perfil  on public.perfis;
create policy ler_perfil  on public.perfis         for select to authenticated using (user_id = auth.uid());
drop policy if exists ler_abast   on public.abastecimentos;
create policy ler_abast   on public.abastecimentos for select to authenticated using (public.eh_autorizado());
drop policy if exists ler_pag     on public.pagamentos;
create policy ler_pag     on public.pagamentos     for select to authenticated using (public.eh_autorizado());
drop policy if exists ler_aloc    on public.alocacoes;
create policy ler_aloc    on public.alocacoes      for select to authenticated using (public.eh_autorizado());
drop policy if exists ler_hist    on public.historico;
create policy ler_hist    on public.historico      for select to authenticated using (public.eh_autorizado());

-- 7) FUNÇÕES (toda a regra financeira é validada AQUI, não no navegador)
create or replace function public.brl(v numeric) returns text
language sql immutable as $f$
  select 'R$ ' || translate(to_char(v, 'FM999,999,999,990.00'), ',.', '.,')
$f$;

create or replace function public.saldo_pendente() returns numeric
language sql stable security definer set search_path = public as $f$
  select coalesce(sum(pendente), 0) from public.v_abastecimentos where not cancelado
$f$;

-- Envia mensagem ao Telegram (sem derrubar a operação se o Telegram falhar)
create or replace function public.enviar_telegram(p_texto text) returns void
language plpgsql security definer set search_path = public as $f$
declare v_token text; v_ids text; v_id text;
begin
  select valor into v_token from public.app_config where chave = 'telegram_token';
  select valor into v_ids   from public.app_config where chave = 'telegram_chat_ids';
  if v_token is null or v_ids is null or v_token like 'COLE%' or v_ids like 'COLE%' then return; end if;
  foreach v_id in array string_to_array(v_ids, ',') loop
    perform net.http_post(
      url     := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      body    := jsonb_build_object('chat_id', trim(v_id), 'text', p_texto),
      headers := '{"Content-Type":"application/json"}'::jsonb);
  end loop;
exception when others then
  null;
end $f$;

-- NOVO ABASTECIMENTO
create or replace function public.registrar_abastecimento(
  p_data date, p_pessoa text, p_veiculo text, p_placa text, p_valor numeric, p_obs text)
returns uuid language plpgsql security definer set search_path = public as $f$
declare v_id uuid; v_num int;
begin
  if not public.eh_admin() then raise exception 'Aviso: você não tem permissão para registrar.'; end if;
  perform pg_advisory_xact_lock(7001);
  if p_data is null then raise exception 'Aviso: informe a data do abastecimento.'; end if;
  if trim(coalesce(p_pessoa,'')) = '' or trim(coalesce(p_veiculo,'')) = '' then
    raise exception 'Aviso: informe a pessoa e o veículo.'; end if;
  if p_valor is null or p_valor <= 0 then raise exception 'Aviso: informe um valor maior que zero.'; end if;

  insert into public.abastecimentos(data, pessoa, veiculo, placa, valor, observacoes)
  values (p_data, trim(p_pessoa), trim(p_veiculo), nullif(upper(trim(coalesce(p_placa,''))),''),
          round(p_valor,2), nullif(trim(coalesce(p_obs,'')),''))
  returning id, numero into v_id, v_num;

  perform public.enviar_telegram(
    E'⛽ NOVO ABASTECIMENTO\n\nPessoa: ' || trim(p_pessoa) ||
    E'\nVeículo: ' || trim(p_veiculo) ||
    case when nullif(trim(coalesce(p_placa,'')),'') is not null then ' (' || upper(trim(p_placa)) || ')' else '' end ||
    E'\nData: ' || to_char(p_data,'DD/MM/YYYY') ||
    E'\nValor: ' || public.brl(round(p_valor,2)) ||
    E'\nSituação: Pendente\n\nTotal pendente atualizado: ' || public.brl(public.saldo_pendente()) || '.');
  return v_id;
end $f$;

-- CORRIGIR ABASTECIMENTO (o histórico guarda o antes e o depois)
create or replace function public.editar_abastecimento(
  p_id uuid, p_data date, p_pessoa text, p_veiculo text, p_placa text, p_valor numeric, p_obs text)
returns void language plpgsql security definer set search_path = public as $f$
declare v_pago numeric; v_a public.abastecimentos;
begin
  if not public.eh_admin() then raise exception 'Aviso: você não tem permissão para editar.'; end if;
  perform pg_advisory_xact_lock(7001);
  select * into v_a from public.abastecimentos where id = p_id for update;
  if not found then raise exception 'Aviso: abastecimento não encontrado.'; end if;
  if v_a.cancelado then raise exception 'Aviso: este abastecimento está cancelado.'; end if;
  if p_data is null or trim(coalesce(p_pessoa,'')) = '' or trim(coalesce(p_veiculo,'')) = '' then
    raise exception 'Aviso: preencha data, pessoa e veículo.'; end if;
  if p_valor is null or p_valor <= 0 then raise exception 'Aviso: informe um valor maior que zero.'; end if;
  select coalesce(sum(al.valor),0) into v_pago
    from public.alocacoes al join public.pagamentos pg on pg.id = al.pagamento_id
   where al.abastecimento_id = p_id and not pg.estornado;
  if round(p_valor,2) < v_pago then
    raise exception 'Aviso: este abastecimento já recebeu % em pagamentos. O valor não pode ser menor que isso.', public.brl(v_pago);
  end if;
  update public.abastecimentos
     set data = p_data, pessoa = trim(p_pessoa), veiculo = trim(p_veiculo),
         placa = nullif(upper(trim(coalesce(p_placa,''))),''), valor = round(p_valor,2),
         observacoes = nullif(trim(coalesce(p_obs,'')),'')
   where id = p_id;
  perform public.enviar_telegram(
    E'✏️ ABASTECIMENTO CORRIGIDO\n\nAbastecimento nº ' || v_a.numero || ' (' || trim(p_pessoa) || E')\nValor: ' ||
    public.brl(round(p_valor,2)) || E'\n\nSaldo pendente atualizado: ' || public.brl(public.saldo_pendente()) || '.');
end $f$;

-- CANCELAR ABASTECIMENTO (o registro nunca é apagado; só se não houver pagamento ativo)
create or replace function public.cancelar_abastecimento(p_id uuid) returns void
language plpgsql security definer set search_path = public as $f$
declare v_a public.abastecimentos;
begin
  if not public.eh_admin() then raise exception 'Aviso: você não tem permissão.'; end if;
  perform pg_advisory_xact_lock(7001);
  select * into v_a from public.abastecimentos where id = p_id for update;
  if not found then raise exception 'Aviso: abastecimento não encontrado.'; end if;
  if exists (select 1 from public.alocacoes al join public.pagamentos pg on pg.id = al.pagamento_id
              where al.abastecimento_id = p_id and not pg.estornado) then
    raise exception 'Aviso: este abastecimento já recebeu pagamento. Estorne o pagamento primeiro.';
  end if;
  update public.abastecimentos set cancelado = true where id = p_id;
  perform public.enviar_telegram(
    E'🚫 ABASTECIMENTO CANCELADO\n\nAbastecimento nº ' || v_a.numero || ' (' || v_a.pessoa || ', ' ||
    public.brl(v_a.valor) || E')\n\nSaldo pendente atualizado: ' || public.brl(public.saldo_pendente()) || '.');
end $f$;

-- REGISTRAR PAGAMENTO COM BAIXA AUTOMÁTICA (FIFO: do mais antigo para o mais novo)
create or replace function public.registrar_pagamento(
  p_chave uuid, p_data date, p_valor numeric, p_forma text, p_obs text)
returns jsonb language plpgsql security definer set search_path = public as $f$
declare
  v_pg uuid; v_total numeric; v_rest numeric; v_aloc numeric; r record;
  v_q int := 0; v_p int := 0; v_n int := 0; v_txt text := '';
begin
  if not public.eh_admin() then raise exception 'Aviso: você não tem permissão para registrar pagamentos.'; end if;
  perform pg_advisory_xact_lock(7001);              -- um pagamento por vez

  -- Já processado antes? (clique duplicado / falha de conexão) -> não baixa de novo
  select id into v_pg from public.pagamentos where chave = p_chave;
  if found then
    return jsonb_build_object('pagamento_id', v_pg, 'repetido', true,
                              'saldo_pendente', public.saldo_pendente());
  end if;

  if p_data is null then raise exception 'Aviso: informe a data do pagamento.'; end if;
  if p_valor is null or round(p_valor,2) <= 0 then raise exception 'Aviso: informe um valor maior que zero.'; end if;
  if p_forma not in ('Pix','Dinheiro','Transferência') then raise exception 'Aviso: forma de pagamento inválida.'; end if;

  v_total := public.saldo_pendente();
  if round(p_valor,2) > v_total then
    raise exception 'Aviso: o pagamento (%) é maior que a dívida total (%). Informe no máximo %.',
      public.brl(round(p_valor,2)), public.brl(v_total), public.brl(v_total);
  end if;

  insert into public.pagamentos(chave, data, valor, forma, observacao)
  values (p_chave, p_data, round(p_valor,2), p_forma, nullif(trim(coalesce(p_obs,'')),''))
  returning id into v_pg;

  v_rest := round(p_valor,2);
  for r in select id, numero, data, pessoa, pendente from public.v_abastecimentos
            where not cancelado and pendente > 0
            order by data, criado_em, id loop
    exit when v_rest <= 0;
    v_aloc := least(v_rest, r.pendente);
    insert into public.alocacoes(pagamento_id, abastecimento_id, valor) values (v_pg, r.id, v_aloc);
    v_rest := v_rest - v_aloc;
    v_n := v_n + 1;
    if v_aloc = r.pendente then
      v_q := v_q + 1;
      if v_n <= 10 then v_txt := v_txt || E'\n✅ ' || to_char(r.data,'DD/MM') || ' ' || r.pessoa || ': quitado'; end if;
    else
      v_p := v_p + 1;
      if v_n <= 10 then v_txt := v_txt || E'\n⚠️ ' || to_char(r.data,'DD/MM') || ' ' || r.pessoa ||
                          ': parcial, ainda falta ' || public.brl(r.pendente - v_aloc); end if;
    end if;
  end loop;

  if v_rest <> 0 then raise exception 'Erro interno: sobrou valor sem distribuir. Operação desfeita.'; end if;

  perform public.enviar_telegram(
    E'💰 PAGAMENTO REGISTRADO\n\nValor recebido: ' || public.brl(round(p_valor,2)) ||
    E'\nForma: ' || p_forma ||
    E'\nAbastecimentos quitados: ' || v_q ||
    E'\nAbastecimentos parcialmente pagos: ' || v_p || v_txt ||
    E'\n\nSaldo pendente total: ' || public.brl(public.saldo_pendente()) || '.');

  return jsonb_build_object('pagamento_id', v_pg, 'repetido', false, 'quitados', v_q,
                            'parciais', v_p, 'saldo_pendente', public.saldo_pendente());
end $f$;

-- ESTORNAR PAGAMENTO (os valores voltam a ficar pendentes; o registro continua no histórico)
create or replace function public.estornar_pagamento(p_id uuid, p_motivo text default null)
returns numeric language plpgsql security definer set search_path = public as $f$
declare v_p public.pagamentos;
begin
  if not public.eh_admin() then raise exception 'Aviso: você não tem permissão.'; end if;
  perform pg_advisory_xact_lock(7001);
  select * into v_p from public.pagamentos where id = p_id for update;
  if not found then raise exception 'Aviso: pagamento não encontrado.'; end if;
  if v_p.estornado then raise exception 'Aviso: este pagamento já foi estornado.'; end if;
  update public.pagamentos
     set estornado = true, estornado_em = now(), motivo_estorno = nullif(trim(coalesce(p_motivo,'')),'')
   where id = p_id;
  perform public.enviar_telegram(
    E'↩️ PAGAMENTO ESTORNADO\n\nValor estornado: ' || public.brl(v_p.valor) ||
    E' (pagamento de ' || to_char(v_p.data,'DD/MM/YYYY') || E')\n\nSaldo pendente total: ' ||
    public.brl(public.saldo_pendente()) || '.');
  return public.saldo_pendente();
end $f$;

-- Aviso de erro importante (o site chama quando um pagamento falha por motivo inesperado)
create or replace function public.notificar_erro(p_msg text) returns void
language plpgsql security definer set search_path = public as $f$
begin
  if not public.eh_admin() then return; end if;
  perform public.enviar_telegram(E'🚨 ERRO NO PROCESSAMENTO DO PAGAMENTO\n\n' || left(coalesce(p_msg,'sem detalhes'), 300) ||
    E'\n\nConfira a lista de Pagamentos antes de tentar de novo.');
end $f$;

create or replace function public.testar_telegram() returns void
language plpgsql security definer set search_path = public as $f$
begin
  if not public.eh_admin() then raise exception 'Aviso: você não tem permissão.'; end if;
  perform public.enviar_telegram('✅ Teste: o aviso do Telegram está funcionando.');
end $f$;

-- 8) PERMISSÕES FINAIS (fecha tudo e libera só o necessário)
revoke all on all tables in schema public from anon, authenticated;
grant select on public.perfis, public.abastecimentos, public.pagamentos,
                public.alocacoes, public.historico, public.v_abastecimentos to authenticated;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.papel_atual(), public.eh_autorizado(), public.eh_admin() to authenticated;
grant execute on function
  public.registrar_abastecimento(date,text,text,text,numeric,text),
  public.editar_abastecimento(uuid,date,text,text,text,numeric,text),
  public.cancelar_abastecimento(uuid),
  public.registrar_pagamento(uuid,date,numeric,text,text),
  public.estornar_pagamento(uuid,text),
  public.notificar_erro(text),
  public.testar_telegram()
to authenticated;

-- =====================================================================
-- PASSOS MANUAIS DEPOIS DE RODAR ESTE ARQUIVO
--
-- A) Criar os usuários: Authentication > Users > Add user (e-mail + senha,
--    marque "Auto Confirm User"). O PRIMEIRO usuário criado vira admin.
--    Em Authentication > Sign In / Providers, DESLIGUE "Allow new users to sign up".
--
-- B) Liberar os demais (rode uma linha por pessoa, trocando o e-mail):
--    update public.perfis set papel = 'leitura'   -- só consulta (ex.: sua avó)
--     where user_id = (select id from auth.users where email = 'avo@email.com');
--    update public.perfis set papel = 'admin'     -- pode registrar
--     where user_id = (select id from auth.users where email = 'funcionario@email.com');
--
-- C) Telegram (rode numa consulta separada e NÃO salve essa consulta):
--    update public.app_config set valor = 'SEU_TOKEN_DO_BOTFATHER' where chave = 'telegram_token';
--    update public.app_config set valor = '111111111,222222222'     where chave = 'telegram_chat_ids';
--    (cada pessoa precisa abrir o bot e mandar /start antes de receber mensagens)
--    Se uma mensagem não chegar, veja o motivo com:
--    select status_code, content from net._http_response order by created desc limit 5;
--
-- D) Backup: Supabase > Database > Backups (diário nos planos pagos). No plano
--    gratuito, use os botões "Baixar planilha" do site toda semana.
-- =====================================================================
