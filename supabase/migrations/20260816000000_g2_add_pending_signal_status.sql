-- G2: o valor de enum precisa ser aplicado antes de qualquer migration que o use.
-- PostgreSQL não permite usar de forma segura um enum recém-adicionado na mesma
-- transação em que ele é introduzido.
alter type app.appointment_status add value if not exists 'PENDING_SIGNAL';
