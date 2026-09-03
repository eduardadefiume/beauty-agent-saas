import { subirFoto } from '../../../../lib/fotos';

export const dynamic = 'force-dynamic';

// O arquivo de conversa exportado do WhatsApp.
//
// Vai para o balde `clientes`, e não para `conhecimento`, e essa escolha é o
// que faz a exclusão funcionar: `clientes` é o balde do dado de uma pessoa,
// que morre quando ela pede. Um histórico de conversa é dado dela.
export async function POST(request: Request): Promise<Response> {
  return subirFoto(request, 'clientes', 'historico', 'EXPORT_DE_CONVERSA');
}
