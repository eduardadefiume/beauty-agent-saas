import { redirect } from 'next/navigation';
import Configurator from './configurator-real';
import { createSupabaseServerClient } from '../lib/supabase/server';

export const dynamic = 'force-dynamic';

export default async function HomePage() {
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user?.email) {
    redirect('/login');
  }

  return <Configurator user={{ displayName: user.email, email: user.email }} />;
}
