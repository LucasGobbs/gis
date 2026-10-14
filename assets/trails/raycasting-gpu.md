# Um raio por pixel, sem rasterizador

Rasterizadores empurram triângulos para a tela; raycasting puxa: cada pixel dispara seu próprio raio e resolve a interseção. Nesta trilha você vê o pipeline de compute que sustenta isso, a construção do raio a partir da câmera do host e a interseção analítica com um plano — a peça que as cenas de "caminhada sobre papel" usam.

## 1. O pipeline de compute

Uma cena de compute é só uma função `numthreads` rodando numa grade de threads, uma por pixel. Cada thread escreve na sua posição da textura de saída — não existe ordem entre elas nem estado compartilhado.

```
[numthreads(8, 8, 1)]
void computeMain(uint3 id : SV_DispatchThreadID) {
    if (is_outside(id, Uniforms.iResolution)) return;
    float2 fragCoord = frag_coord(id, Uniforms.iResolution);
    out_tex[id.xy] = cor;
}
```

`frag_coord` vira a origem y do dispatch (topo) para convenção de shader de fragmento (base). A independência total entre threads é o contrato: sem contadores, sem acumuladores globais — cada pixel recomputa tudo do zero a cada frame.

[Abrir a cena 09_compute](scene:09_compute): troque `numthreads(8,8,1)` por `(16,16,1)` e confirme que a imagem não muda — o tamanho do bloco é execução, não imagem.

## 2. Do pixel ao raio

O uv centrado vem de `Space::pixel_to_uv` (módulo `space.slang`): x em [-aspecto/2, aspecto/2], y em [-0.5, 0.5], 1 unidade = altura da tela. O módulo `camera.slang` transforma isso em direção 3D com a base que o host fornece:

```
float2 uv = Space::pixel_to_uv(fragCoord, Uniforms.iResolution);
float3 ro = Camera::origin(Uniforms);
float3 rd = Camera::ray(Uniforms, uv, 1.5);
```

O `1.5` é o focal — meia tela ocupa meio radiano aproximado. É o mesmo parâmetro que as cenas 3D passam; mexer nele não move a câmera, só a lente.

## 3. Interseção analítica com o plano do chão

Um plano horizontal y = y0 corta o raio onde a componente y zera. Da equação do raio `p(t) = ro + t * rd` com `p(t).y = y0`:

```
t = -(ro.y - y0) / rd.y
```

Três casos: `rd.y` ~ 0 (raio paralelo, sem solução — ou tudo é plano), `t <= 0` (o plano fica atrás), e o hit válido. O módulo `space.slang` encapsula isso com fallback de "olhar para frente":

```
ponto = Space::plane_hit(ro, rd, y0, fallbackDist);   // float3
t     = Space::ray_t_plane(ro, rd, y0);               // só o parâmetro, -1 se paralelo
```

É exatamente o que o mapeamento plano→mundo faz em cenas de padrão no chão: o `w` do plano (x, z) alimenta o campo, então o desenho mora no chão, não na tela — voar para os lados revela mais chão.

```
float2 w = Space::plane_hit(ro, rd, 0.0, 20.0).xz;
```

## 4. Raycasting analítico contra raymarching

Plano, esfera e caixa alinhada têm solução fechada: uma expressão, zero iteração. Sphere tracing é a alternativa iterativa para formas sem solução fechada (fractais, SDFs compostos). A regra prática:

```
interseção fechada existe? -> resolva a equação, um passo
senão                      -> marche com o SDF, muitos passos
```

As cenas deste projeto misturam as duas: hit de plano analítico para o papel, raymarch para o objeto. Analítico é determinístico e barato; marching é geral e mais caro — a escolha é por forma, não por gosto.

## Próximo passo

Toda essa geometria precisa de matéria: grão de papel, tinta, terreno. Siga a trilha [Aleatoriedade suave](trail:noise-fbm).
