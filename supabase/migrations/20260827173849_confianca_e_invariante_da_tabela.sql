-- A regra da confiança vira invariante da tabela, não regra de quem escreve.
--
-- Ela precisa valer na importação, na gravação pela tela, e em qualquer SQL
-- que alguém rode um dia. Se ficasse dentro de site_import_clients, o próximo
-- caminho de escrita nasceria sem ela -- e ninguém perceberia, porque o
-- sintoma é o agente cobrando retorno de quem não tem hábito nenhum.
--
-- Gatilho, e não constraint CHECK, porque a intenção é CORRIGIR o valor e
-- deixar a escrita passar. Recusar a linha faria uma importação de 286 fichas
-- morrer por causa de um campo cosmético.

create or replace function app.enforce_cadence_confidence()
returns trigger
language plpgsql
as $$
begin
  new.cadence_confidence := app.cadence_confidence_for(new.times_done, new.cadence_confidence);
  return new;
end;
$$;

drop trigger if exists client_procedures_confianca on app.client_procedures;
create trigger client_procedures_confianca
  before insert or update on app.client_procedures
  for each row execute function app.enforce_cadence_confidence();
