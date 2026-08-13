import { COOKIE_NAME } from "@shared/const";
import { getSessionCookieOptions } from "./_core/cookies";
import { systemRouter } from "./_core/systemRouter";
import { publicProcedure, router } from "./_core/trpc";
import { z } from "zod";

let mockServices = [
  { id: 1, name: "Corte Masculino / Barba", price: 90.00, durationMinutes: 45 },
  { id: 2, name: "Corte Estilizado", price: 120.00, durationMinutes: 60 },
  { id: 3, name: "Hidratação Profunda", price: 150.00, durationMinutes: 40 },
];

let mockInboxEvents = [
  {
    id: "ev-001",
    eventType: "whatsapp_text",
    senderContact: "+55 16 99421-5487",
    status: "PENDING_PROVE",
    payload: { message: "Olá William, gostaria de agendar um corte para amanhã às 14h." },
    receivedAt: new Date(Date.now() - 1000 * 60 * 45).toISOString(),
  }
];

export const appRouter = router({
  system: systemRouter,
  auth: router({
    me: publicProcedure.query(opts => opts.ctx.user),
    logout: publicProcedure.mutation(({ ctx }) => {
      const cookieOptions = getSessionCookieOptions(ctx.req);
      ctx.res.clearCookie(COOKIE_NAME, { ...cookieOptions, maxAge: -1 });
      return {
        success: true,
      } as const;
    }),
  }),

  pilot: router({
    getStatus: publicProcedure.query(() => ({
      databaseStatus: "Ativo (Supabase DEV hjghwryhphgusefyivbl)",
      tenantName: "Salão do William",
      allowlistCount: 1,
      allowedNumber: "+55 16 99421-5487",
      statusText: "Pronto para teste controlado e eventos reais",
    })),

    getInboxEvents: publicProcedure.query(() => {
      return mockInboxEvents;
    }),

    getServices: publicProcedure.query(() => {
      return mockServices;
    }),

    addService: publicProcedure
      .input(z.object({
        name: z.string().min(1),
        price: z.number().positive(),
        durationMinutes: z.number().int().positive(),
      }))
      .mutation(({ input }) => {
        const newService = {
          id: Date.now(),
          name: input.name,
          price: input.price,
          durationMinutes: input.durationMinutes,
        };
        mockServices.push(newService);
        return newService;
      }),

    deleteService: publicProcedure
      .input(z.object({ id: z.number() }))
      .mutation(({ input }) => {
        mockServices = mockServices.filter(s => s.id !== input.id);
        return { success: true };
      }),
  }),
});

export type AppRouter = typeof appRouter;
