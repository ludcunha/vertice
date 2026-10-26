-- Conferência da bronze, antes da silver.
--
-- Por quê: a silver confia que a ingestão trouxe tudo. Se um arquivo do data lake
-- não chegou (ou chegou pela metade), a silver rodaria "verde" com menos linhas e
-- os números da Torre sairiam errados sem ninguém perceber. Aqui cada tabela é
-- contada contra o esperado do dataset (seed 42) e a tarefa falha se divergir.
--
-- bronze.feriados fica de fora: ela cresce a cada execução da ingestão.
-- Atenção: a sql_task corta o arquivo em todo ponto e vírgula, então nenhum
-- texto abaixo pode ter esse caractere.

CREATE OR REPLACE TEMPORARY VIEW conferencia AS
WITH esperado AS (
  SELECT * FROM VALUES
    ('projetos',               60),
    ('status_semanal',       3911),
    ('excel_tarefas',        1663),
    ('clickup_tarefas',      2119),
    ('msproject_tarefas',    1260),
    ('colaboradores',         523),
    ('apontamentos',        30883),
    ('custos',              23640),
    ('entregas_fornecedor',   640)
  AS t(tabela, esperado)
),
obtido AS (
  SELECT 'projetos'            AS tabela, count(*) AS obtido FROM lakehouse_vertice.bronze.projetos
  UNION ALL SELECT 'status_semanal',      count(*) FROM lakehouse_vertice.bronze.status_semanal
  UNION ALL SELECT 'excel_tarefas',       count(*) FROM lakehouse_vertice.bronze.excel_tarefas
  UNION ALL SELECT 'clickup_tarefas',     count(*) FROM lakehouse_vertice.bronze.clickup_tarefas
  UNION ALL SELECT 'msproject_tarefas',   count(*) FROM lakehouse_vertice.bronze.msproject_tarefas
  UNION ALL SELECT 'colaboradores',       count(*) FROM lakehouse_vertice.bronze.colaboradores
  UNION ALL SELECT 'apontamentos',        count(*) FROM lakehouse_vertice.bronze.apontamentos
  UNION ALL SELECT 'custos',              count(*) FROM lakehouse_vertice.bronze.custos
  UNION ALL SELECT 'entregas_fornecedor', count(*) FROM lakehouse_vertice.bronze.entregas_fornecedor
)
SELECT
  e.tabela,
  e.esperado,
  coalesce(o.obtido, 0) AS obtido,
  CASE WHEN e.esperado = coalesce(o.obtido, 0) THEN 'ok' ELSE 'DIVERGENTE' END AS resultado
FROM esperado e
LEFT JOIN obtido o USING (tabela);

-- Uma linha por tabela: esperado × obtido.
SELECT tabela, esperado, obtido, resultado FROM conferencia ORDER BY tabela;

-- Se alguma tabela divergir, a tarefa falha dizendo qual e onde olhar.
SELECT
  CASE
    WHEN count_if(resultado <> 'ok') > 0 THEN raise_error(concat(
      'Bronze divergente em: ',
      array_join(collect_list(CASE WHEN resultado <> 'ok'
        THEN concat(tabela, ' (esperado ', esperado, ', obtido ', obtido, ')') END), ', '),
      '. Olhe a saída da tarefa ingestao_data_lake do job vertice_farol.'))
    ELSE concat('bronze ok: ', count(*), ' de 9 tabelas com a contagem esperada')
  END AS conferencia_bronze
FROM conferencia;
