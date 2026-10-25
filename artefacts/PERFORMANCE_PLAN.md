# Plano de desempenho e compatibilidade — Shader Explorer

## Objetivo

Executar a trilha de aprendizagem em computadores de laboratório sem GPU dedicada, com uso de CPU e memória baixo o bastante para uma aula completa. Os números abaixo são orçamentos provisórios; não descrevem o estado atual até serem medidos.

## Perfil mínimo alvo

- CPU: 4 núcleos de notebook;
- memória: 8 GB;
- GPU: integrada, com backend Vulkan ou Metal aceito pela SDL3 GPU;
- resolução inicial: 1280×720;
- monitor: 60 Hz;
- sistema: macOS ou Linux na primeira validação; Windows depois da validação SPIR-V/DXIL;
- sem exigência de GPU dedicada.

## Orçamentos provisórios

| Métrica | Meta inicial | Observação |
|---|---:|---|
| RSS do processo principal em repouso | ≤ 150 MB | build release, cena estática |
| RSS combinado (app + slangd) | ≤ 250 MB | sem goose-build em execução |
| pico combinado durante recompilação | ≤ 500 MB | inclui subprocesso de compilação |
| CPU em repouso | ≤ 5% de um núcleo | janela visível, cena estática |
| frame time p95, trilha 01–07 | ≤ 16,7 ms | 720p, 60 FPS |
| frame time p95, cenas 3D/multipass | ≤ 33,3 ms | 720p, 30 FPS mínimo |
| inicialização a frio | ≤ 5 s | até primeira cena utilizável |
| sessão contínua | 60 min sem crescimento sustentado | memória e handles estáveis |

As metas deverão ser revistas depois do primeiro baseline em hardware fraco. O objetivo não é perseguir números arbitrários, mas impedir regressões que excluam laboratórios comuns.

## Baseline inicial — Apple M4 / Metal

Build usado:

```text
-o:aggressive -microarch:native -no-bounds-check -disable-assert
-define:HOT_RELOAD=true
```

Cenário: janela visível, cena `01_hello_pixel`, editor aberto, 30 segundos, amostragem a cada 0,5 s por `tools/measure_perf.py`. O percentual de CPU do `ps` equivale à fração de um núcleo lógico.

| Versão | CPU total mediana | RSS combinado mediana | RSS combinado pico |
|---|---:|---:|---:|
| polling de cenas por frame | 22,4% | 246,0 MB | 249,6 MB |
| polling limitado a 10 Hz | 6,7% | 187,2 MB | 257,1 MB |


Medição adicional após catálogo lazy:

| Cenário | RSS combinado mediana | RSS combinado pico |
|---|---:|---:|
| startup carregando somente cena 01 | 124,9 MB | 151,9 MB |

Arquivo bruto: `perf/lazy_scene_startup.csv`. A CPU dessa execução não é comparável ao baseline porque a janela não permaneceu no mesmo estado de apresentação. A memória inclui o processo principal e `slangd`.
O ganho de CPU é atribuível ao intervalo de polling: o restante do cenário foi mantido. A queda de RSS mediana não deve ser atribuída à mesma mudança. Na segunda execução, o processo principal passou de aproximadamente 105 para 62 MB e o `slangd` de 149 para 18 MB depois de cerca de 20 segundos, provavelmente por liberação ou reclaim de páginas. O pico de startup permaneceu próximo de 257 MB. Um teste mais longo e repetido em hardware fraco será necessário antes de revisar os budgets.

Dados brutos:

- `perf/idle_static.csv`;
- `perf/idle_static_poll10hz.csv`.

### Defeito encontrado no build release

O build com `-disable-assert` encerrava com `SIGSEGV`. A inicialização do backend ImGui SDL_GPU estava dentro de `assert(im_sdlgpu.Init(...))`; ao remover asserts, a chamada inteira desaparecia. A inicialização foi separada da verificação e o release voltou a executar `--once` com sucesso. Esse caso será usado como regra de revisão: `assert` não pode envolver chamadas com efeito colateral.

## Custos atuais identificados no código

### 1. Cenas sob demanda — parcialmente implementado

O catálogo descobre todos os títulos, mas startup e hot reload agora geram manifesto somente para a cena ativa. Módulos `pass_*.slang` da cena entram no mesmo manifesto, e imports como `common.slang` são resolvidos pelo Slang. A cena 10, por exemplo, gera apenas `10_multipass.slang` e `pass_1.slang`.

Estado atual:

- startup compila e cria pipelines apenas para a cena selecionada;
- mudança em cena ativa recompila somente essa cena;
- mudança em `common.slang` recompila a cena ativa;
- cena não carregada é compilada quando selecionada;
- cenas já visitadas continuam em memória sem limite.

Próximo passo:

- cache LRU com 2–4 cenas;
- liberar pipelines da cena menos recente;
- carregar a próxima cena em background para evitar pausa síncrona na troca;
- registrar hit/miss do cache e memória por troca.

### 2. Modelos e texturas são carregados de forma antecipada

O `main.odin` carrega todas as texturas de papel, skyboxes e todos os modelos no startup.

Mudança proposta:

- manter apenas metadados e caminhos na inicialização;
- carregar modelo, skybox ou textura quando uma cena solicitar;
- cache de assets com limite em bytes;
- fallback pequeno para cenas sem asset selecionado;
- liberar assets não usados depois de um intervalo ou sob pressão de memória.

### 3. O watcher varre cenas a cada frame

`scene_poll` é chamado no loop principal e consulta diretórios e mtimes de cenas.

Mudança proposta:

- limitar o polling a 4–10 vezes por segundo;
- evitar repetir `stat` para módulos que não mudaram;
- considerar watcher nativo somente depois de medir a solução com intervalo;
- suspender polling quando a janela estiver minimizada, exceto se houver build pendente.

### 4. O servidor de linguagem pode ser iniciado sob demanda

O `slangd` só é necessário quando o editor está aberto ou há arquivos sendo editados.

Mudança proposta:

- iniciar `slangd` ao abrir o editor pela primeira vez;
- encerrar depois de longo período sem editor aberto, se o custo de reabrir for aceitável;
- medir processo principal e servidor separadamente.

### 5. Renderização contínua de cenas estáticas

Cenas que não usam tempo, mouse ou animação não precisam gerar nova textura a cada frame.

Mudança proposta:

- marcar cena como suja quando shader, parâmetro, mouse, câmera, asset ou tamanho mudar;
- renderizar sob demanda quando a cena for estática;
- manter loop contínuo para cenas que usam `iTime` ou input animado;
- suspender renderização quando a janela estiver minimizada.

A detecção automática de uso de `iTime` pode vir da reflexão ou de análise do módulo. Até isso estar disponível, usar flag explícita por cena.

### 6. Resolução e previews

Mudança proposta:

- escala de renderização 0,5× / 0,75× / 1×;
- default 0,75× em perfil de hardware baixo;
- previews do node editor em resolução reduzida;
- limitar atualização de thumbnails a 10–15 FPS;
- desativar previews automaticamente sob pressão de GPU.

### 7. Recursos de debug devem ser opcionais

- não criar buffers de watches quando o painel Debug estiver desligado;
- alocar buffer de registros sob demanda;
- limitar quantidade de watches;
- usar readback assíncrono e double buffering;
- não bloquear o frame esperando a GPU.

## Ordem de desenvolvimento

### Fase 0 — baseline

1. build release com hot reload;
2. medir os cenários abaixo;
3. salvar CSV e informações da máquina;
4. registrar CPU, RSS do app, RSS do `slangd`, frame time CPU/GPU e tempo de startup.

### Fase 1 — baixo risco

1. limitar polling de arquivos;
2. suspender trabalho quando minimizado;
3. limitar FPS de previews;
4. iniciar `slangd` sob demanda;
5. adicionar escala de renderização.

### Fase 2 — memória e startup

1. lazy loading de modelos/texturas/skyboxes;
2. cena ativa carregada sob demanda;
3. cache LRU de pipelines;
4. cache de assets limitado em bytes.

### Fase 3 — renderização sob demanda

1. dirty flag de cena;
2. flag explícita `animated` no metadata da cena;
3. atualização somente quando necessário;
4. medição de consumo em sessão de 60 minutos.

### Fase 4 — matriz de compatibilidade

1. Apple Silicon / Metal;
2. Intel ou AMD integrada / Vulkan;
3. notebook com 8 GB de RAM;
4. Windows / Vulkan ou D3D12;
5. registrar falhas, FPS, CPU, memória e tempo de instalação.

## Cenários de benchmark

| Cenário | Duração | O que medir |
|---|---:|---|
| startup a frio | 1 execução × 5 | tempo até cena 01 utilizável, pico de memória |
| idle, cena estática | 60 s | CPU, RSS, frame time |
| cena animada 02_time | 60 s | CPU/GPU p50/p95/p99 |
| cena 3D 08_lighting3d | 60 s | CPU/GPU, VRAM estimada |
| cena 10_multipass | 60 s | frame time, previews ligados/desligados |
| edição e rebuild | 10 alterações | pico de RSS, CPU, processo slangc |
| troca de cenas | trilha 01–10 | tempo de troca, cache, memória |
| sessão de aula | 60 min | crescimento de RSS, handles, estabilidade |
| janela minimizada | 60 s | CPU e wakeups |

## Dados de ambiente

Cada execução deverá registrar:

- CPU e quantidade de núcleos;
- RAM instalada;
- GPU e memória compartilhada/dedicada;
- sistema operacional;
- backend SDL3 GPU;
- resolução e escala de renderização;
- commit do Shader Explorer, goose e Slang;
- flags de build;
- cenas e assets usados.

## Critério de aceitação para a aula piloto

Antes da aplicação em sala:

- não crescer memória durante teste de 60 minutos;
- abrir a cena 01 em até 5 segundos na máquina-alvo;
- manter interação fluida em 720p;
- concluir a trilha 01–07 sem GPU dedicada;
- executar rebuild sem fechar o programa;
- manter uso combinado abaixo dos limites definidos ou documentar a exceção;
- possuir fallback de resolução e previews.

## Resultado esperado

O trabalho de otimização deverá produzir:

1. baseline reproduzível;
2. budgets revisados a partir de dados;
3. matriz de hardware suportado;
4. requisitos mínimos publicados;
5. testes de regressão para memória e startup;
6. seção técnica do artigo baseada em evidência, separada dos resultados didáticos.
