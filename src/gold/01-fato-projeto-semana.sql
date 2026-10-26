-- gold.fato_projeto_semana: o filme do projeto, uma linha por projeto e sexta-feira.
--
-- Por quê: a pergunta 1 do dono ("quais projetos estão atrasados?") precisa da
-- curva, não só da foto. As ferramentas (Excel, ClickUp, Project) só guardam o %
-- de hoje, então o histórico do avanço vem do status semanal: o EV de cada sexta
-- usa o % que o gerente publicou naquela sexta. O PV vem do baseline das tarefas
-- e o AC do custo real acumulado.
--
--   PV  = orçamento × Σ horas × fração do baseline decorrida até a semana ÷ Σ horas
--   EV  = orçamento × % concluído do status daquela sexta ÷ 100
--   AC  = custo real acumulado até a semana
--   SPI = EV ÷ PV (< 1 é atraso) · CPI = EV ÷ AC (< 1 é estouro) · EAC = orçamento ÷ CPI
--
-- "Hoje" é DATE'2026-10-16' (sexta). Nunca current_date(): o número mudaria todo dia.
-- Funções de janela ficam num CTE e a agregação em outro (juntas, dão erro no pipeline).

CREATE OR REFRESH MATERIALIZED VIEW lakehouse_vertice.gold.fato_projeto_semana (
  CONSTRAINT pv_nao_negativo    EXPECT (pv >= 0)         ON VIOLATION FAIL UPDATE,
  CONSTRAINT ev_ate_o_orcamento EXPECT (ev <= orcamento) ON VIOLATION FAIL UPDATE
)
COMMENT 'Fato semanal de cada projeto (uma linha por projeto_id e semana, a sexta-feira), da semana do início até 16/10/2026. pv = valor planejado pelo baseline das tarefas, ev = valor agregado pelo % do status semanal daquela sexta, ac = custo real acumulado, spi = ev/pv (< 1 atraso), cpi = ev/ac (< 1 estouro), eac = orcamento/cpi. farol_do_gerente é o último farol publicado até a semana. horas_disponiveis, horas_apontadas e horas_ociosas somam o timesheet do projeto na semana. Valores em R$.'
AS
WITH semanas AS (
  -- Todas as sextas, da semana do início do projeto até hoje
  SELECT
    projeto_id,
    orcamento_custo AS orcamento,
    explode(sequence(
      date_add(CAST(date_trunc('WEEK', data_inicio) AS DATE), 4),
      DATE'2026-10-16',
      INTERVAL 1 WEEK)) AS semana
  FROM projetos
),

pv_semana AS (
  -- Fração do baseline de cada tarefa já decorrida na semana (0 a 1), ponderada pelas horas
  SELECT
    s.projeto_id,
    s.semana,
    sum(t.horas * CASE
          WHEN t.fim_baseline <= t.inicio_baseline THEN IF(s.semana >= t.fim_baseline, 1, 0)
          ELSE greatest(0, least(1, datediff(s.semana, t.inicio_baseline)
                                    / datediff(t.fim_baseline, t.inicio_baseline)))
        END)          AS horas_planejadas,
    sum(t.horas)      AS horas_totais
  FROM semanas s
  JOIN tarefas t
    ON t.projeto_id = s.projeto_id
  GROUP BY s.projeto_id, s.semana
),

status_da_sexta AS (
  -- Um status por projeto e sexta (garante que o join abaixo não duplica semanas)
  SELECT
    projeto_id,
    data_status,
    max(pct_concluido) AS pct_concluido,
    max(farol)         AS farol
  FROM status_semanal
  GROUP BY projeto_id, data_status
),

status_semana AS (
  -- Projeto concluído não publica mais status: vale o último % e o último farol
  SELECT
    s.projeto_id,
    s.semana,
    last_value(st.pct_concluido, true) OVER w AS pct_status,
    last_value(st.farol, true)         OVER w AS farol_do_gerente
  FROM semanas s
  LEFT JOIN status_da_sexta st
    ON st.projeto_id = s.projeto_id
   AND st.data_status = s.semana
  WINDOW w AS (PARTITION BY s.projeto_id ORDER BY s.semana)
),

custo_semana AS (
  SELECT projeto_id, semana, sum(valor) AS custo
  FROM custos
  GROUP BY projeto_id, semana
),

ac_semana AS (
  -- Acumulado: tudo o que foi lançado até a semana (inclui lançamento anterior ao início)
  SELECT
    s.projeto_id,
    s.semana,
    coalesce(sum(c.custo), 0) AS ac
  FROM semanas s
  LEFT JOIN custo_semana c
    ON c.projeto_id = s.projeto_id
   AND c.semana <= s.semana
  GROUP BY s.projeto_id, s.semana
),

horas_semana AS (
  SELECT
    projeto_id,
    semana,
    sum(horas_disponiveis)                                AS horas_disponiveis,
    sum(horas_apontadas)                                  AS horas_apontadas,
    sum(greatest(horas_disponiveis - horas_apontadas, 0)) AS horas_ociosas
  FROM apontamentos
  GROUP BY projeto_id, semana
),

base AS (
  SELECT
    s.projeto_id,
    s.semana,
    s.orcamento,
    round(s.orcamento * try_divide(pv.horas_planejadas, pv.horas_totais), 2)  AS pv,
    round(s.orcamento * coalesce(st.pct_status, 0) / 100, 2)                  AS ev,
    CAST(ac.ac AS DECIMAL(18, 2))                                             AS ac,
    st.farol_do_gerente,
    coalesce(h.horas_disponiveis, 0) AS horas_disponiveis,
    coalesce(h.horas_apontadas, 0)   AS horas_apontadas,
    coalesce(h.horas_ociosas, 0)     AS horas_ociosas
  FROM semanas s
  LEFT JOIN pv_semana     pv ON pv.projeto_id = s.projeto_id AND pv.semana = s.semana
  LEFT JOIN status_semana st ON st.projeto_id = s.projeto_id AND st.semana = s.semana
  LEFT JOIN ac_semana     ac ON ac.projeto_id = s.projeto_id AND ac.semana = s.semana
  LEFT JOIN horas_semana  h  ON h.projeto_id  = s.projeto_id AND h.semana  = s.semana
),

kpis AS (
  SELECT
    *,
    round(try_divide(ev, pv), 4) AS spi,
    round(try_divide(ev, ac), 4) AS cpi
  FROM base
)

SELECT
  projeto_id,
  semana,
  orcamento,
  pv,
  ev,
  ac,
  spi,
  cpi,
  round(try_divide(orcamento, cpi), 2) AS eac,
  farol_do_gerente,
  horas_disponiveis,
  horas_apontadas,
  horas_ociosas
FROM kpis;
