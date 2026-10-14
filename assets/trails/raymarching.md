# Caminhar até a superfície

Em 3D você não avalia o SDF na tela inteira: dispara um raio por pixel e caminha ao longo dele até tocar a superfície. Essa técnica é o sphere tracing (raymarching por distância). Aqui você entende o laço, o critério de parada, a normal e a sombra suave — a espinha dorsal das cenas 3D deste projeto.

## 1. O raio e o laço de distância

Um raio é origem `ro` mais direção `rd`: pontos `p(t) = ro + t * rd`, com `t >= 0`. A promessa do SDF: avaliar `d(p)` dá um passo seguro — nenhum ponto num raio de `d` pertence à superfície. Então ande exatamente `d` e repita:

```
t = 0.0
for i in 0..MAX_STEPS:
    p = ro + rd * t
    d = sdf(p)
    if d < eps: hit em t
    t += d
    if t > T_MAX: errou
```

Cada passo reutiliza o campo: perto de superfícies os passos encurtam (e o custo cresce), no vazio eles alongam. É por isso que cenas com muito espaço vazio são baratas.

[Abrir a cena 08_lighting3d](scene:08_lighting3d): aumente `MAX_STEPS` para 200 e compare a silhueta; depois reduza para 16 e observe onde o laço desiste.

## 2. Critério de parada dependente da distância

Comparar `d < eps` com eps fixo marca pixels de longe como hit (um eps de 0.001 a 200 unidades é tempo demais). O critério correto escala eps com o caminho já percorrido:

```
if d < eps * t: hit
```

A tolerância cresce com a distância — longe, um pixel cobre muito mundo, então exatidão lá embaixo é desperdício. A cena apple2 usa essa forma.

[Abrir a cena apple2](scene:apple2): troque o critério `d < 0.001 * t` por `d < 0.001` e procure o halo errado que aparece ao redor da maçã.

## 3. A normal sai do próprio campo

A superfície não tem malha: a normal é o gradiente do campo, aproximado por diferenças centrais — meia unidade para cada lado em cada eixo, e normalize:

```
calcNormal(p):
    e = 0.001
    n.x = sdf(p + (e,0,0)) - sdf(p - (e,0,0))
    n.y = sdf(p + (0,e,0)) - sdf(p - (0,e,0))
    n.z = sdf(p + (0,0,e)) - sdf(p - (0,0,e))
    return normalize(n)
```

São 6 avaliações extras do SDF por pixel iluminado — o principal custo de um raymarcher. A direção `n` aponta para fora; luz = `saturate(dot(n, L))`.

[Abrir a cena 08_lighting3d](scene:08_lighting3d): mude o `e` para 0.1 e veja as bordas perderem detalhe; mova `L` e observe a sombra girar sem tocar no SDF.

## 4. Sombra suave: marchar de novo, mas barato

Sombra é a mesma caminhada, do ponto iluminado em direção à luz, guardando o menor quociente distância/avanço:

```
softShadow(ro, L):
    res = 1.0; t = 0.02
    for i in 0..SHADOW_STEPS:
        h = sdf(ro + L * t)
        res = min(res, k * h / t)
        t += clamp(h, 0.01, 0.5)
        if res < 0.005 or t > T_MAX: break
    return saturate(res)
```

O `k` controla a suavidade: k grande (10+) encosta em sombra dura, k pequeno espalha a penumbra. Nenhum buffer de profundidade — só o campo, de novo.

[Abrir a cena apple2](scene:apple2): localize o `k` da sombra, divida por 3, e compare a penumbra da maçã sobre o papel.

## 5. De onde vem o raio

A origem e a base do raio chegam prontas em `SceneUniforms`: `iCameraPosition`, `iCameraForward`, `iCameraRight`, `iCameraUp` são calculadas em Odin (órbita automática ou flycam) e o módulo `camera.slang` monta o raio:

```
rd = Camera::ray(Uniforms, uv, 1.5);   // focal escolhido pela cena
ro = Camera::origin(Uniforms);
```

O uv aqui vem de `Space::pixel_to_uv` (módulo `space.slang`): centrado, com 1 unidade = altura da tela. Você nunca move a câmera no shader — o visitor é movido pelo host.

[Abrir a cena 08_lighting3d](scene:08_lighting3d): troque o focal 1.5 por 1.0 e depois por 3.0 — é o zoom da lente, sem tocar na posição.

## Próximo passo

Sphere tracing caminha; nem toda interseção precisa de laço. Um plano tem solução fechada. Siga a trilha [Um raio por pixel, sem rasterizador](trail:raycasting-gpu).
