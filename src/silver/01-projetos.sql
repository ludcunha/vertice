-- silver.projetos: o cadastro do PMO, limpo e tipado.
--
-- Por quê: é o de-para da integração. Cada projeto diz em qual ferramenta é
-- controlado (excel, clickup ou msproject) e qual é o código dele lá dentro
-- (nome do arquivo, list_id do ClickUp ou nome do XML). silver.tarefas usa esta
-- tabela para saber de qual projeto é cada tarefa.
--
-- Sujeiras tratadas (CLAUDE.md, seção 3):
--   #1 data_inicio em yyyy-MM-dd e dd/MM/yyyy → coalesce de dois try_to_date
--   #2 ferramenta escrita de 8 jeitos → excel / clickup / msproject (o original fica em ferramenta_como_veio)
--   #3 codigo_ferramenta vazio → NULL (tarefas resolve pelo nome do arquivo ou da lista)

CREATE OR REFRESH MATERIALIZED VIEW projetos (
  CONSTRAINT data_inicio_valida   EXPECT (data_inicio IS NOT NULL)                         ON VIOLATION FAIL UPDATE,
  CONSTRAINT ferramenta_conhecida EXPECT (ferramenta IN ('excel', 'clickup', 'msproject')) ON VIOLATION FAIL UPDATE
)
COMMENT 'Cadastro dos 60 projetos da Vértice (PMO): cliente, segmento, contrato, orçamento, datas, gerente e a ferramenta onde cada projeto é controlado (excel, clickup ou msproject) com o código do projeto nela. É o de-para que integra as três ferramentas em silver.tarefas.'
AS SELECT
  projeto_id,
  nome_projeto,
  cliente,
  segmento,
  tipo_projeto,
  -- 'Excel', 'excel', 'Planilha' / 'ClickUp', 'Clickup' / 'MS Project', 'Project', 'msproject'
  CASE
    WHEN lower(ferramenta) LIKE '%click%'                                   THEN 'clickup'
    WHEN lower(ferramenta) LIKE '%project%'                                 THEN 'msproject'
    WHEN lower(ferramenta) LIKE '%excel%' OR lower(ferramenta) LIKE '%planilha%' THEN 'excel'
  END                                                    AS ferramenta,
  ferramenta                                             AS ferramenta_como_veio,
  nullif(trim(codigo_ferramenta), '')                    AS codigo_ferramenta,
  CAST(valor_contrato  AS DECIMAL(18, 2))                AS valor_contrato,
  CAST(orcamento_custo AS DECIMAL(18, 2))                AS orcamento_custo,
  coalesce(try_to_date(data_inicio, 'yyyy-MM-dd'),
           try_to_date(data_inicio, 'dd/MM/yyyy'))       AS data_inicio,
  coalesce(try_to_date(data_fim_baseline, 'yyyy-MM-dd'),
           try_to_date(data_fim_baseline, 'dd/MM/yyyy')) AS data_fim_baseline,
  status,
  gerente_projeto
FROM lakehouse_vertice.bronze.projetos;
