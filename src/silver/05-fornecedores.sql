-- silver.entregas_fornecedor: prometido × entregue das consultorias.
--
-- Por quê: a pergunta 4 do dono ("o que vai dar errado no próximo mês?") começa
-- pelas entregas de consultoria atrasadas. Fornecedor não tem tabela gold:
-- dashboard e Genie leem direto daqui.
--
--   #15 a CodeForge vem de 4 jeitos ('CodeForge Consultoria Ltda', 'Codeforge Consultoria',
--       'CODEFORGE CONSULTORIA LTDA', 'Code Forge Consultoria'). Sem normalizar, ela vira
--       4 fornecedores pequenos e o atraso dela some. O original fica em fornecedor_como_veio.
--   data_entrega vazia = entrega em aberto (não é sujeira).
--   "Hoje" é 16/10/2026: nunca current_date(), senão o número muda todo dia.

CREATE OR REFRESH MATERIALIZED VIEW entregas_fornecedor
COMMENT 'Entregas contratadas das consultorias por projeto: datas de pedido, prometida e de entrega, prazos em dias e atraso. em_aberto = ainda não entregue. em_atraso = em aberto com a data prometida antes de hoje (16/10/2026). Fornecedor com nome normalizado (a CodeForge vinha escrita de 4 jeitos).'
AS
WITH tipado AS (
  SELECT
    entrega_id,
    projeto_id,
    CASE WHEN replace(lower(fornecedor), ' ', '') LIKE '%codeforge%'
         THEN 'CodeForge Consultoria Ltda'
         ELSE fornecedor END                  AS fornecedor,
    fornecedor                                AS fornecedor_como_veio,
    item,
    CAST(valor AS DECIMAL(18, 2))             AS valor,
    to_date(data_pedido)                      AS data_pedido,
    to_date(data_prometida)                   AS data_prometida,
    to_date(data_entrega)                     AS data_entrega,
    CAST(prazo_contratado_dias AS INT)        AS prazo_contratado_dias,
    status
  FROM lakehouse_vertice.bronze.entregas_fornecedor
)
SELECT
  *,
  datediff(data_prometida, data_pedido)                  AS prazo_prometido_dias,
  datediff(data_entrega,   data_pedido)                  AS prazo_real_dias,     -- NULL se em aberto
  greatest(datediff(data_entrega, data_prometida), 0)    AS dias_de_atraso_na_entrega,  -- 0 = no prazo ou antes
  data_entrega IS NULL                                   AS em_aberto,
  data_entrega IS NULL AND data_prometida < DATE'2026-10-16' AS em_atraso
FROM tipado;
