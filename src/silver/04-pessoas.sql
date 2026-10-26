-- silver.colaboradores e silver.apontamentos.
--
-- Por quê: a pergunta 3 do dono ("tenho gente parada enquanto outro projeto pede
-- gente?") sai do timesheet cruzado com o cadastro de pessoas. Uma pessoa
-- cadastrada duas vezes dobraria as horas dela na utilização.

-- ---------------------------------------------------------------------------
-- colaboradores
--   #16 COL0102, COL0257 e COL0433 aparecem duas vezes: a cópia tem nome e papel
--       em CAIXA ALTA. Fica o cadastro com o papel em minúsculas.
-- ---------------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW colaboradores
COMMENT 'Cadastro das 520 pessoas da Vértice (uma linha por colaborador_id): papel, senioridade, custo por hora, data de admissão e de desligamento (NULL = ativo).'
AS
WITH numerado AS (
  SELECT
    c.*,
    row_number() OVER (
      PARTITION BY colaborador_id
      ORDER BY CASE WHEN papel = lower(papel) THEN 0 ELSE 1 END
    ) AS ordem
  FROM lakehouse_vertice.bronze.colaboradores c
)
SELECT
  colaborador_id,
  nome,
  papel,
  senioridade,
  CAST(custo_hora AS DECIMAL(10, 2)) AS custo_hora,
  to_date(data_admissao)             AS data_admissao,
  to_date(data_desligamento)         AS data_desligamento
FROM numerado
WHERE ordem = 1;

-- ---------------------------------------------------------------------------
-- apontamentos: o timesheet semanal.
--   semana = semana_inicio (segunda) + 4 = a sexta, a mesma data do status semanal.
-- ---------------------------------------------------------------------------
CREATE OR REFRESH MATERIALIZED VIEW apontamentos
COMMENT 'Timesheet semanal: horas disponíveis e horas apontadas por colaborador e projeto. semana_inicio é a segunda-feira e semana é a sexta-feira da mesma semana (casa com status_semanal e custos).'
AS SELECT
  colaborador_id,
  projeto_id,
  to_date(semana_inicio)               AS semana_inicio,
  date_add(to_date(semana_inicio), 4)  AS semana,
  CAST(horas_disponiveis AS DOUBLE)    AS horas_disponiveis,
  CAST(horas_apontadas   AS DOUBLE)    AS horas_apontadas
FROM lakehouse_vertice.bronze.apontamentos;
