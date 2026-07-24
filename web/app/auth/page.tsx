import { AuthShell } from "@/components/auth-shell";

type AuthPageProps = {
  searchParams?: Promise<{
    provider?: string;
    status?: string;
    next?: string;
  }>;
};

export default async function AuthPage({ searchParams }: AuthPageProps) {
  const params = await searchParams;

  return (
    <main className="flex min-h-dvh flex-col items-center justify-center bg-paper px-6 py-16">
      <div className="w-full max-w-[420px]">
        <div className="mb-7 text-center">
          <span className="text-4xl font-semibold tracking-[-0.02em] text-ink">
            I<span className="io-scan">{"//"}</span>O
          </span>
        </div>
        <AuthShell
          initialProvider={params?.provider}
          initialStatus={params?.status}
          next={params?.next}
        />
      </div>
    </main>
  );
}
