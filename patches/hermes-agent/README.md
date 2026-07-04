# Hermes Agent runtime overlays

Patches deste diretório são reaplicados pelo `deploy-instance.sh` sobre arquivos
extraídos da imagem Hermes pinada. O container recebe os arquivos por bind mount;
nenhuma edição manual é feita dentro dele.

## `media-caption.patch`

Adiciona a diretiva `MEDIA_CAPTION:{"path":...,"caption":...,"type":"video"|"image"}`
para entrega de mídia local com legenda nativa (caption presa à bolha da mídia,
como no envio manual do Telegram/WhatsApp). Substitui o antigo
`video-caption.patch`, que cobria apenas vídeos.

- O `type` é obrigatório e precisa concordar com a extensão do arquivo
  (vídeo: mp4/mov/avi/mkv/webm/3gp/m4v; imagem: jpg/jpeg/png/webp/gif).
- Imagens são entregues via `send_image_file(caption=...)`; vídeos via
  `send_video(caption=...)`. A ordem das diretivas na resposta é preservada.
- O fluxo existente de imagens markdown (`![legenda](https://...)`) não é
  interceptado nem alterado — a diretiva é opt-in por ferramenta.

O deploy executa `git apply --check` e `py_compile` antes de reiniciar o gateway.
Se uma atualização da imagem tornar o patch incompatível, o deploy para e exige
que o patch seja refeito sobre o novo `main` do Hermes Agent.
