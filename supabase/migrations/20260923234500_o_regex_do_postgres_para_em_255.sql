-- O REGEX DO POSTGRES PARA EM 255, E ELE NAO AVISA NA HORA DE CRIAR.
--
-- 23/09/2026, minutos depois de aplicar a 20260923194500. A trava do nome do
-- modelo nasceu assim:
--
--   template_name text not null check (template_name ~ '^[a-z0-9_]{1,512}$')
--
-- 512 porque e o limite real da Meta para nome de modelo. Mas o Postgres
-- recusa contagem de repeticao acima de 255, e devolve
-- "invalid regular expression: invalid repetition count(s)".
--
-- O QUE FAZ ISSO SER PERIGOSO, E NAO SO ERRADO: o `create table` ACEITOU a
-- restricao sem reclamar. O regex so e compilado quando alguem insere uma
-- linha. Entao a migration aplicou "com sucesso", a tabela existe, o
-- `information_schema` mostra tudo certo -- e QUALQUER tentativa de registrar
-- um modelo estouraria com uma mensagem que nao tem nada a ver com o que a
-- pessoa estava fazendo.
--
-- Ninguem teria descoberto isso lendo o codigo. Quem descobriu foi o teste
-- s10, na primeira vez que ele chamou `registrar_modelo_aprovado` -- que e
-- exatamente o passo que a Eduarda ia rodar depois de criar o modelo na tela
-- da Meta. Sem o teste, o erro apareceria para ela, sem contexto, com o modelo
-- ja aprovado do outro lado.
--
-- A correcao separa as duas coisas que o regex tentava fazer junto: o
-- ALFABETO fica no regex (que e o que regex faz bem) e o TAMANHO vira
-- comparacao de inteiro (que nao tem teto). Continua valendo os mesmos 512.
--
-- Varri as 210 migrations e as Edge Functions atras de outras repeticoes acima
-- de 255: esta era a unica. Nao havia nenhuma anterior a mim.

alter table app.message_templates
  drop constraint if exists message_templates_template_name_check;

alter table app.message_templates
  add constraint message_templates_template_name_check
  check (
    template_name ~ '^[a-z0-9_]+$'
    and length(template_name) <= 512
  );

comment on column app.message_templates.template_name is
  'Nome do modelo como ele existe na Meta: minusculas, digitos e underscore, ate 512 caracteres. O limite e checado por length e nao por regex porque o Postgres recusa repeticao acima de 255 -- e so avisa disso na hora do insert.';
