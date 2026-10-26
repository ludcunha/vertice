-- silver.tarefas: AS TRÊS FERRAMENTAS VIRAM UMA.
--
-- Por quê: 20 projetos estão em planilhas Excel, 25 no ClickUp e 15 no MS Project.
-- Cada ferramenta guarda a tarefa de um jeito (texto, milissegundos, XML com
-- tarefas-resumo). Para calcular SPI de todos os projetos do mesmo jeito, as três
-- precisam virar um modelo só. Cada ferramenta ganha uma visão temporária com as
-- MESMAS 13 colunas, e a materialized view no fim é só o UNION ALL das três.
--
-- O projeto de cada tarefa vem do de-para em silver.projetos (codigo_ferramenta).
-- Quando o código falta, há um plano B por ferramenta (nome do arquivo ou da lista).

-- ---------------------------------------------------------------------------
-- Excel: tudo chega como texto.
--   #4 datas em dd/MM/yyyy (com '/') ou número de série do Excel (dias desde 30/12/1899)
--   #5 % em '45%', '10,5%' ou fração 0.45
--   #6 linha de TOTAL no fim de cada planilha (somaria as horas duas vezes)
--   #7 horas em '40h'
--   #3 código vazio, ou arquivo sem acento ('Core bancario' × 'Core bancário'):
--      o PRJ-xxx do nome do arquivo resolve
-- ---------------------------------------------------------------------------
CREATE TEMPORARY VIEW tarefas_excel AS
SELECT
  coalesce(p.projeto_id, nullif(regexp_extract(e.arquivo, 'PRJ-[0-9]{3}', 0), '')) AS projeto_id,
  'excel'                                   AS ferramenta,
  CAST(e.id AS STRING)                      AS id_na_ferramenta,
  e.fase,
  e.tarefa,
  e.responsavel,
  CASE WHEN e.inicio_previsto  LIKE '%/%' THEN to_date(e.inicio_previsto, 'dd/MM/yyyy')
       ELSE date_add(DATE'1899-12-30', CAST(e.inicio_previsto AS INT)) END  AS inicio_baseline,
  CASE WHEN e.termino_previsto LIKE '%/%' THEN to_date(e.termino_previsto, 'dd/MM/yyyy')
       ELSE date_add(DATE'1899-12-30', CAST(e.termino_previsto AS INT)) END AS fim_baseline,
  CASE WHEN e.inicio_real      LIKE '%/%' THEN to_date(e.inicio_real, 'dd/MM/yyyy')
       ELSE date_add(DATE'1899-12-30', CAST(e.inicio_real AS INT)) END      AS inicio_real,
  CASE WHEN e.termino_real     LIKE '%/%' THEN to_date(e.termino_real, 'dd/MM/yyyy')
       ELSE date_add(DATE'1899-12-30', CAST(e.termino_real AS INT)) END     AS fim_real,
  CASE WHEN instr(e.pct_concluido, '%') > 0
       THEN CAST(replace(replace(e.pct_concluido, '%', ''), ',', '.') AS DOUBLE)
       ELSE CAST(e.pct_concluido AS DOUBLE) * 100 END                       AS pct_como_veio,
  CAST(replace(e.horas_previstas, 'h', '') AS DOUBLE)                       AS horas,
  CAST(NULL AS STRING)                      AS status_na_ferramenta  -- a planilha não tem status
FROM lakehouse_vertice.bronze.excel_tarefas e
LEFT JOIN projetos p
  ON p.codigo_ferramenta = e.arquivo
WHERE e.tarefa <> 'TOTAL';

-- ---------------------------------------------------------------------------
-- ClickUp: JSON da API.
--   #8 datas em milissegundos; %, baseline e fase dentro de custom_fields (lista)
--   #9 status escrito de 12 jeitos → concluida / a_fazer / em_andamento
--   #3 list_id vazio no cadastro: casa pelo nome da lista
-- ---------------------------------------------------------------------------
CREATE TEMPORARY VIEW tarefas_clickup AS
SELECT
  coalesce(pc.projeto_id, pn.projeto_id)    AS projeto_id,
  'clickup'                                 AS ferramenta,
  c.id                                      AS id_na_ferramenta,
  filter(c.custom_fields, f -> f.name = 'Fase')[0].value AS fase,
  c.name                                    AS tarefa,
  c.assignees[0].username                   AS responsavel,
  to_date(timestamp_millis(CAST(filter(c.custom_fields, f -> f.name = 'Início baseline')[0].value AS BIGINT))) AS inicio_baseline,
  to_date(timestamp_millis(CAST(filter(c.custom_fields, f -> f.name = 'Fim baseline')[0].value AS BIGINT)))    AS fim_baseline,
  to_date(timestamp_millis(CAST(c.start_date AS BIGINT))) AS inicio_real,
  to_date(timestamp_millis(CAST(c.date_done  AS BIGINT))) AS fim_real,
  CAST(filter(c.custom_fields, f -> f.name = 'Progresso (%)')[0].value AS DOUBLE) AS pct_como_veio,
  c.time_estimate / 3600000.0               AS horas,  -- time_estimate vem em milissegundos
  CASE
    WHEN lower(c.status.status) IN ('done', 'closed', 'concluído')                     THEN 'concluida'
    WHEN lower(c.status.status) IN ('to do', 'a fazer', 'backlog')                     THEN 'a_fazer'
    WHEN lower(c.status.status) IN ('in progress', 'doing', 'em andamento', 'review')  THEN 'em_andamento'
  END                                       AS status_na_ferramenta
FROM lakehouse_vertice.bronze.clickup_tarefas c
LEFT JOIN projetos pc
  ON pc.codigo_ferramenta = c.list_id
LEFT JOIN projetos pn
  ON pc.projeto_id IS NULL
 AND pn.ferramenta = 'clickup'
 AND pn.codigo_ferramenta IS NULL
 AND pn.nome_projeto = c.list_name;

-- ---------------------------------------------------------------------------
-- MS Project: as <Task> do XML.
--   #10 tarefas-resumo (Summary = 1) somam as de baixo: ficam fora
--   #11 a fase não está na tarefa: é a última tarefa-resumo de nível 1 antes dela
--       (a janela roda ANTES do filtro, senão as linhas de fase já teriam sumido)
--   #12 horas em 'PT40H0M0S'
-- ---------------------------------------------------------------------------
CREATE TEMPORARY VIEW tarefas_msproject AS
WITH com_fase AS (
  SELECT
    m.*,
    last_value(CASE WHEN m.OutlineLevel = 1 THEN m.Name END, true)
      OVER (PARTITION BY m.arquivo ORDER BY m.UID) AS fase
  FROM lakehouse_vertice.bronze.msproject_tarefas m
)
SELECT
  p.projeto_id,
  'msproject'                               AS ferramenta,
  CAST(t.UID AS STRING)                     AS id_na_ferramenta,
  t.fase,
  t.Name                                    AS tarefa,
  CAST(NULL AS STRING)                      AS responsavel,  -- o XML exportado não traz o recurso
  to_date(t.Baseline.Start)                 AS inicio_baseline,
  to_date(t.Baseline.Finish)                AS fim_baseline,
  to_date(t.ActualStart)                    AS inicio_real,
  to_date(t.ActualFinish)                   AS fim_real,
  CAST(t.PercentComplete AS DOUBLE)         AS pct_como_veio,
  CAST(regexp_extract(t.Work, 'PT([0-9]+)H', 1) AS DOUBLE) AS horas,
  CAST(NULL AS STRING)                      AS status_na_ferramenta  -- o Project só tem o %
FROM com_fase t
LEFT JOIN projetos p
  ON p.codigo_ferramenta = t.arquivo
WHERE t.Summary = 0;

-- ---------------------------------------------------------------------------
-- O modelo único. O contrato (FAIL UPDATE) garante que toda tarefa achou o seu
-- projeto, que o % está entre 0 e 100 e que toda tarefa tem horas.
-- O % acima de 100 (11 linhas do Excel) é cortado em 100, com flag.
-- ---------------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW tarefas (
  CONSTRAINT achou_o_projeto   EXPECT (projeto_id IS NOT NULL)           ON VIOLATION FAIL UPDATE,
  CONSTRAINT pct_entre_0_e_100 EXPECT (pct_concluido BETWEEN 0 AND 100)  ON VIOLATION FAIL UPDATE,
  CONSTRAINT horas_positivas   EXPECT (horas > 0)                        ON VIOLATION FAIL UPDATE
)
COMMENT 'Todas as tarefas dos 60 projetos num modelo só, integrando as três ferramentas (Excel, ClickUp e MS Project): fase, responsável, datas baseline e reais, % concluído (0 a 100) e horas previstas. Uma linha por tarefa (tarefa_id = projeto-ferramenta-id). Base do SPI da fotografia de hoje.'
AS
WITH todas AS (
  SELECT * FROM tarefas_excel
  UNION ALL
  SELECT * FROM tarefas_clickup
  UNION ALL
  SELECT * FROM tarefas_msproject
)
SELECT
  concat_ws('-', projeto_id, ferramenta, id_na_ferramenta) AS tarefa_id,
  projeto_id,
  ferramenta,
  id_na_ferramenta,
  fase,
  tarefa,
  responsavel,
  inicio_baseline,
  fim_baseline,
  inicio_real,
  fim_real,
  pct_como_veio,
  least(pct_como_veio, 100)  AS pct_concluido,
  pct_como_veio > 100        AS pct_veio_acima_de_100,
  horas,
  status_na_ferramenta
FROM todas;
