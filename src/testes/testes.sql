-- Testes de qualidade entre tabelas (sql_task, depois do medalhão).
--
-- Por quê: o EXPECT do pipeline olha linha a linha. Estes testes olham o que só
-- aparece cruzando tabelas: a integração das três ferramentas, a limpeza que não
-- pode mudar o total e a gold que tem que bater com a silver. Cada teste devolve
-- 'ok: ...' ou para o job com raise_error dizendo o que quebrou.
--
-- Atenção: a sql_task corta o arquivo em todo ponto e vírgula, então só os fins de
-- comando o usam. "Hoje" é DATE'2026-10-16'.

-- 1 · os 60 projetos têm cronograma na silver.tarefas
SELECT CASE
  WHEN count(*) = 60 AND count_if(t.projeto_id IS NULL) = 0
    THEN 'ok 1: os 60 projetos têm cronograma na silver.tarefas'
  ELSE raise_error(concat('teste 1: projetos sem tarefa na silver.tarefas: ',
       coalesce(array_join(collect_list(CASE WHEN t.projeto_id IS NULL THEN p.projeto_id END), ', '), '-'),
       ' (de ', count(*), ' projetos)'))
END AS teste_01
FROM lakehouse_vertice.silver.projetos p
LEFT JOIN (SELECT DISTINCT projeto_id FROM lakehouse_vertice.silver.tarefas) t
  ON t.projeto_id = p.projeto_id;

-- 2 · cada projeto veio de UMA ferramenta, a do cadastro do PMO
SELECT CASE
  WHEN count(*) = 0 THEN 'ok 2: cada projeto veio de uma ferramenta só, a do cadastro'
  ELSE raise_error(concat('teste 2: projeto com ferramenta errada ou misturada: ',
       array_join(collect_list(concat(projeto_id, ' (', ferramentas, ' x cadastro ', cadastro, ')')), ', ')))
END AS teste_02
FROM (
  SELECT t.projeto_id,
         array_join(array_sort(collect_set(t.ferramenta)), '+') AS ferramentas,
         max(p.ferramenta)                                      AS cadastro
  FROM lakehouse_vertice.silver.tarefas t
  JOIN lakehouse_vertice.silver.projetos p ON p.projeto_id = t.projeto_id
  GROUP BY t.projeto_id
  HAVING count(DISTINCT t.ferramenta) > 1 OR max(t.ferramenta) <> max(p.ferramenta)
);

-- 3 · as horas do Excel na silver = a soma das linhas de TOTAL das planilhas
SELECT CASE
  WHEN abs(silver - total_planilhas) < 0.01
    THEN concat('ok 3: horas do Excel na silver = TOTAL das planilhas (', silver, ' h)')
  ELSE raise_error(concat('teste 3: horas do Excel na silver (', silver,
       ') diferente da soma das linhas de TOTAL (', total_planilhas, ')'))
END AS teste_03
FROM (
  SELECT
    (SELECT sum(horas) FROM lakehouse_vertice.silver.tarefas WHERE ferramenta = 'excel') AS silver,
    (SELECT sum(CAST(replace(horas_previstas, 'h', '') AS DOUBLE))
       FROM lakehouse_vertice.bronze.excel_tarefas WHERE tarefa = 'TOTAL')                AS total_planilhas
);

-- 4 · uma linha por pessoa na silver
SELECT CASE
  WHEN count(*) = count(DISTINCT colaborador_id)
    THEN concat('ok 4: uma linha por pessoa (', count(*), ' colaboradores)')
  ELSE raise_error(concat('teste 4: silver.colaboradores tem ', count(*), ' linhas para ',
       count(DISTINCT colaborador_id), ' pessoas'))
END AS teste_04
FROM lakehouse_vertice.silver.colaboradores;

-- 5 · a CodeForge virou um fornecedor só
SELECT CASE
  WHEN count(DISTINCT fornecedor) = 1
    THEN concat('ok 5: a CodeForge é um fornecedor só (', max(fornecedor), ', ', count(*), ' entregas)')
  ELSE raise_error(concat('teste 5: a CodeForge ainda aparece com ', count(DISTINCT fornecedor), ' grafias: ',
       array_join(collect_set(fornecedor), ' / ')))
END AS teste_05
FROM lakehouse_vertice.silver.entregas_fornecedor
WHERE replace(lower(fornecedor_como_veio), ' ', '') LIKE '%codeforge%';

-- 6 · a limpeza não mudou o custo total (bronze com replace = silver)
SELECT CASE
  WHEN bronze = silver THEN concat('ok 6: custo total igual na bronze e na silver (R$ ', silver, ')')
  ELSE raise_error(concat('teste 6: custo total mudou na limpeza: bronze R$ ', bronze, ' x silver R$ ', silver))
END AS teste_06
FROM (
  SELECT
    (SELECT sum(CAST(replace(valor, ',', '.') AS DECIMAL(18, 2))) FROM lakehouse_vertice.bronze.custos) AS bronze,
    (SELECT sum(valor) FROM lakehouse_vertice.silver.custos)                                             AS silver
);

-- 7 · os 60 projetos têm fotografia de hoje
SELECT CASE
  WHEN count(*) = 60 AND count(DISTINCT projeto_id) = 60
    THEN 'ok 7: os 60 projetos têm fotografia de hoje'
  ELSE raise_error(concat('teste 7: gold.projeto_situacao_atual tem ', count(*), ' linhas e ',
       count(DISTINCT projeto_id), ' projetos (esperado 60)'))
END AS teste_07
FROM lakehouse_vertice.gold.projeto_situacao_atual;

-- 8 · todo projeto em andamento tem SPI e CPI
SELECT CASE
  WHEN count_if(spi IS NULL OR cpi IS NULL) = 0
    THEN concat('ok 8: os ', count(*), ' projetos em andamento têm SPI e CPI')
  ELSE raise_error(concat('teste 8: projeto em andamento sem SPI ou CPI: ',
       array_join(collect_list(CASE WHEN spi IS NULL OR cpi IS NULL THEN projeto_id END), ', ')))
END AS teste_08
FROM lakehouse_vertice.gold.projeto_situacao_atual
WHERE status = 'em_andamento';

-- 9 · o EV de hoje do status semanal bate com o das ferramentas (diferença < 1%, na carteira)
SELECT CASE
  WHEN abs(ev_status - ev_ferramentas) / ev_ferramentas < 0.01
    THEN concat('ok 9: EV de hoje do status (R$ ', ev_status, ') bate com o das ferramentas (R$ ',
                ev_ferramentas, '), diferença ', round(100 * abs(ev_status - ev_ferramentas) / ev_ferramentas, 2), '%')
  ELSE raise_error(concat('teste 9: EV de hoje do status (R$ ', ev_status, ') x das ferramentas (R$ ',
       ev_ferramentas, '): diferença de ', round(100 * abs(ev_status - ev_ferramentas) / ev_ferramentas, 2), '%'))
END AS teste_09
FROM (
  SELECT
    (SELECT sum(ev) FROM lakehouse_vertice.gold.fato_projeto_semana WHERE semana = DATE'2026-10-16') AS ev_status,
    (SELECT sum(ev) FROM lakehouse_vertice.gold.projeto_situacao_atual)                               AS ev_ferramentas
);

-- 10 · AC de hoje no fato = soma dos lançamentos até hoje
SELECT CASE
  WHEN ac_fato = ac_lancamentos THEN concat('ok 10: AC de hoje no fato = lançamentos até hoje (R$ ', ac_fato, ')')
  ELSE raise_error(concat('teste 10: AC de hoje no fato (R$ ', ac_fato, ') x lançamentos até hoje (R$ ',
       ac_lancamentos, ')'))
END AS teste_10
FROM (
  SELECT
    (SELECT sum(ac) FROM lakehouse_vertice.gold.fato_projeto_semana WHERE semana = DATE'2026-10-16')     AS ac_fato,
    (SELECT sum(valor) FROM lakehouse_vertice.silver.custos WHERE data <= DATE'2026-10-16')              AS ac_lancamentos
);
