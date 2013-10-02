require_dependency 'spree/calculator'
module Spree
  class Calculator::Avatax < Spree::Calculator
        def self.description
          I18n.t(:avalara_tax)
        end

        def compute(computable)
          case computable
            when Spree::Order
              compute_order(computable)
            when Spree::LineItem
              compute_line_item(computable)
          end
        end

        private

          def rate
            self.calculable
          end

          def compute_order(order)
            #Use Avatax lookup and if fails fall back to default Spree taxation rules
            begin
              Avalara.password = AvataxConfig.password
              Avalara.username = AvataxConfig.username
              Avalara.endpoint = AvataxConfig.endpoint

              matched_line_items = order.line_items.select do |line_item|
                line_item.product.tax_category == rate.tax_category
              end

              invoice_lines =[]
              line_count = 0

              discount = 0
              credits = order.adjustments.select {|a| a.amount<0}
              discount = -(credits.sum &:amount)
              matched_line_items.each do |matched_line_item|
                line_count = line_count + 1
                matched_line_amount = matched_line_item.price * matched_line_item.quantity
                invoice_line = Avalara::Request::Line.new(
                  :line_no => line_count.to_s,
                  :destination_code => '1',
                  :origin_code => '1',
                  :qty => matched_line_item.quantity.to_s,
                  :amount => matched_line_amount.to_s,
                  :discounted => true
                )
                invoice_lines << invoice_line
              end

              invoice_addresses = []
              invoice_address = Avalara::Request::Address.new(
                :address_code => '1',
                :line_1 => order.ship_address.address1.to_s,
                :line_2 => order.ship_address.address2.to_s,
                :city => order.ship_address.city.to_s,
                :postal_code => order.ship_address.zipcode.to_s
              )
              invoice_addresses << invoice_address

              #Log Order State
              logger.debug order.state

              invoice = Avalara::Request::Invoice.new(
                :customer_code => order.email,
                :doc_date => Date.today,
                :doc_type => 'SalesOrder',
                :company_code => AvataxConfig.company_code,
                :doc_code => order.number,
                :discount => discount.to_s
              )

              invoice.addresses = invoice_addresses
              invoice.lines = invoice_lines

              #Log request
              logger.debug invoice.to_s

              invoice_tax = Avalara.get_tax(invoice)

              #Log Response
              logger.debug invoice_tax.to_s
              invoice_tax.total_tax

            rescue
              matched_line_items = order.line_items.select do |line_item|
                line_item.product.tax_category == rate.tax_category
              end
              line_items_total = matched_line_items.sum(&:total)
              round_to_two_places(line_items_total * rate.amount)
            end
          end

          def compute_line_item(line_item)
            #Use Avatax lookup and if fails fall back to default Spree taxation rules
            begin
              #TODO-  Line Item Lookup
            rescue
              if line_item.product.tax_category == rate.tax_category
                deduced_total_by_rate(line_item.total, rate)
              else
                0
              end
            end
          end

          def round_to_two_places(amount)
            BigDecimal.new(amount.to_s).round(2, BigDecimal::ROUND_HALF_UP)
          end

          def deduced_total_by_rate(total, rate)
            round_to_two_places(total - ( total / (1 + rate.amount) ) )
          end
       end
end
