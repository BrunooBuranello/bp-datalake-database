-- ============================================================
-- ZSDBIL17 - DEMO HISTORY
-- 09 - CAMPANHA: REGULARIZAÇÃO DEMO VENCIDOS ATÉ 19/11/2026
-- ============================================================
-- Pedido de 06/11/2026 (Felipe Mendes): os DEMO vencidos da
-- lista enviada devem ser vendidos até 19/11. Enquanto a
-- campanha vale, esses ciclos vencem em 19/11 e voltam de
-- OVERDUE para WARNING; o aviso por grupo mostra o texto
-- abaixo e a relação dos chassis da campanha.
--
-- Regras:
-- - match_type CHASSIS_LIST: só os chassis carregados em
--   dim_demo_campaign_chassis (carga pelo comando do app
--   load_demo_campaign_chassis; a planilha não vai para o Git);
-- - issuance_to = 06/11/2026: só ciclos já emitidos entram;
--   um DEMO novo do mesmo chassi não herda o prazo;
-- - fixed_due_date = 19/11/2026 e aviso no dia 20 (já passou:
--   o ciclo fica WARNING até 19/11);
-- - vigência 06/11 a 19/11/2026: a partir de 20/11 a campanha
--   deixa de valer e o ciclo volta ao prazo padrão (vencido
--   desde o vencimento original);
-- - priority 200: vence campanhas por modelo (Shark = 100).
--
-- Este script é idempotente (ON DUPLICATE KEY UPDATE).
-- Rodar depois do 08.
-- ============================================================

INSERT INTO bp_datalake.dim_demo_campaign (
    campaign_code,
    campaign_name,
    reference_document,
    match_type,
    model_simplified_prefix,
    model_year,
    issuance_from,
    issuance_to,
    warning_days,
    due_days,
    fixed_due_date,
    valid_from,
    valid_to,
    priority,
    active,
    notes,
    message_before_table,
    updated_by
)
VALUES (
    'REGULARIZACAO_DEMO_20261119_FELIPE_MENDES',
    'Regularização DEMO vencidos - até 19/11',
    'Solicitação Felipe Mendes 06/11/2026',
    'CHASSIS_LIST',
    NULL,
    NULL,
    '2026-01-01',
    '2026-11-06',
    20,
    NULL,
    '2026-11-19',
    '2026-11-06',
    '2026-11-19',
    200,
    1,
    'Lista de DEMO vencidos para venda até 19/11/2026; depois volta ao prazo padrão.',
    CONCAT(
        'A fim de regularizarmos a situação dos veículos de demonstração vencidos, ',
        'pedimos por gentileza que realizem as vendas dos chassis abaixo até 19/11.',
        '\n',
        'Os pedidos podem ser criados através do CRM nas modalidades de: Venda Direta, ',
        'Test Drive ou Atacado. Todo pedido criado e enviado para aprovação no sistema ',
        'até essa data terá sequência no seu faturamento com base no pedido criado. ',
        'Caso nenhum pedido seja criado até a data de 19/11, os veículos serão ',
        'faturados para estoque da concessionária.',
        '\n',
        'Caso encontrem algum problema sistêmico para a inclusão dos chassis em um ',
        'pedido do sistema, por gentileza, retornem neste e-mail informando qual o ',
        'chassi e qual a dificuldade sistêmica.',
        '\n',
        'Abaixo a relação:'
    ),
    CURRENT_USER()
)
ON DUPLICATE KEY UPDATE
    campaign_name = VALUES(campaign_name),
    reference_document = VALUES(reference_document),
    match_type = VALUES(match_type),
    model_simplified_prefix = VALUES(model_simplified_prefix),
    model_year = VALUES(model_year),
    issuance_from = VALUES(issuance_from),
    issuance_to = VALUES(issuance_to),
    warning_days = VALUES(warning_days),
    due_days = VALUES(due_days),
    fixed_due_date = VALUES(fixed_due_date),
    valid_from = VALUES(valid_from),
    valid_to = VALUES(valid_to),
    priority = VALUES(priority),
    active = VALUES(active),
    notes = VALUES(notes),
    message_before_table = VALUES(message_before_table),
    updated_by = VALUES(updated_by);

SELECT campaign_code, match_type, fixed_due_date, valid_from, valid_to, priority, active
FROM bp_datalake.dim_demo_campaign
WHERE campaign_code = 'REGULARIZACAO_DEMO_20261119_FELIPE_MENDES';
