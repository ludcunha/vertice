-- silver.status_semanal e silver.custos.
--
-- Por quê: o status de sexta é o histórico do avanço (as ferramentas só guardam
-- o % de hoje) e os custos são o AC do CPI. Os dois só precisam de tipo certo e
-- de duas decisões de negócio: status vazio NÃO é descartado e estorno NÃO sai.

-- ---------------------------------------------------------------------------
-- status_semanal
--   #17 farol 'Verde', 'VERDE' → lower(trim())
--   #18 texto vazio ('', 'N/A', 'ver ata da reunião') → flag status_vazio (a linha fica:
--       o % e o farol da semana continuam valendo)
-- ---------------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW status_semanal (
  CONSTRAINT farol_valido EXPECT (farol IN ('verde', 'amarelo', 'vermelho')) ON VIOLATION FAIL UPDATE
)
COMMENT 'Status semanal (toda sexta) de cada projeto: farol do gerente (verde, amarelo, vermelho), % concluído declarado e o texto livre com entregas e bloqueios. status_vazio marca os textos sem conteúdo (vazio, N/A, ver ata da reunião), que são mantidos.'
AS SELECT
  projeto_id,
  to_date(data_status)            AS data_status,
  gerente,
  lower(trim(farol))              AS farol,
  CAST(pct_concluido AS INT)      AS pct_concluido,
  texto_status,
  (texto_status IS NULL
   OR trim(texto_status) IN ('', 'N/A', 'ver ata da reunião')) AS status_vazio
FROM lakehouse_vertice.bronze.status_semanal;

-- ---------------------------------------------------------------------------
-- custos
--   #13 vírgula decimal em 671 valores ('12345,67'): replace ANTES do CAST.
--       Nunca try_cast: ele viraria NULL em silêncio e R$ 5,4 mi sumiriam do custo.
--       Com CAST, um valor estranho derruba o pipeline e alguém olha.
--   #14 estorno (valor negativo) FICA: o custo é líquido. A coluna estorno sinaliza.
--   semana = a sexta da semana do lançamento, para casar com o status semanal.
-- ---------------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW custos
COMMENT 'Lançamentos de custo real por projeto (pessoal, consultoria, cloud, licenças, despesas), valor em R$ já líquido de estornos. estorno marca os lançamentos negativos. semana é a sexta-feira da semana do lançamento.'
AS SELECT
  lancamento_id,
  projeto_id,
  to_date(data)                                                AS data,
  date_add(CAST(date_trunc('WEEK', to_date(data)) AS DATE), 4) AS semana,
  categoria,
  descricao,
  CAST(replace(valor, ',', '.') AS DECIMAL(18, 2))             AS valor,
  CAST(replace(valor, ',', '.') AS DECIMAL(18, 2)) < 0         AS estorno,
  centro_custo
FROM lakehouse_vertice.bronze.custos;
